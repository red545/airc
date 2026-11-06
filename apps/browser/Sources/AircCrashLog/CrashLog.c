// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Fatal signals of the browser process (docs/user/telemetry.md, "Crash reports").
//
// Every build writes a compact crash record at signal time, which the next launch turns into a `$exception` event
// (AircKit's CrashReport.parseSignalRecord) when sharing is on. macOS's own crash report (.ips) often never comes:
// ReportCrash gives up on a process as big as Chromium's browser. The record holds the build, the signal, its code and
// fault address, the crashed thread's return addresses, and the binaries they fall in: name (never a path), UUID, load
// address and __TEXT size, for Airc's own binaries and the system's only. Nothing a page, a URL or a file name holds.
// Dev and test builds also write Crash.log, a human-readable copy with symbols (best effort).
//
// The handler is async-signal-safe: no allocation, no locks, no stdio. The files are opened and the binaries listed at
// install (dyld's add-image callback keeps the list current), memory is read with vm_read_overwrite (a bad frame
// pointer fails the read instead of faulting), and the output goes through a static buffer to the pre-opened fd.
//
// Chaining: installed last (main.swift installs again after Chromium starts, whose non-official builds install a
// stack dumper). After writing, the handler restores whatever was there before (that handler, or the default action)
// and returns: a fault recurs at the same instruction, so the previous handler and macOS's crash report see the
// original exception where it happened; a raised or sent signal (abort, kill) is raised again, pending until return.
#include "AircCrashLog.h"
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

enum { kMaxImages = 4096, kMaxFrames = 128, kRecordsKept = 3 };
static const int kSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE };
#define SIGNAL_COUNT (sizeof(kSignals) / sizeof(kSignals[0]))

// Binaries: Airc's own (inside the bundle) and the system's. Any other binary is nobody we name.
struct image {
    uint64_t base, size;
    uint8_t uuid[16];
    char origin;   // 'a' Airc's bundle, 's' the system's
    char name[80];
};
static struct image images[kMaxImages];
static _Atomic uint32_t image_count;   // entries below it are complete
static pthread_mutex_t image_lock = PTHREAD_MUTEX_INITIALIZER;
static const struct mach_header *main_header;
static char bundle_prefix[2][PATH_MAX + 2];   // as given and resolved, with a trailing slash

static int installed;
static int record_fd = -1, log_fd = -1;
static char record_header[512];
static size_t record_header_size;
static char log_header[65536];
static size_t log_header_size;
static struct sigaction previous[SIGNAL_COUNT];
static _Atomic int claimed, finished;
static pthread_t claimant;
static char alternate_stack[65536];
static uintptr_t frames[kMaxFrames];
static uint8_t used[kMaxImages];

// MARK: Output (signal time)

static char out[16384];
static size_t out_size;
static int out_fd = -1;

static void put(int fd, const char *s, size_t n) {
    while (n) {
        ssize_t count = write(fd, s, n);
        if (count <= 0) break;
        s += count;
        n -= (size_t)count;
    }
}
static void flush(void) {
    if (out_fd >= 0 && out_size) put(out_fd, out, out_size);
    out_size = 0;
}
static void emit(const char *s, size_t n) {
    while (n) {
        if (out_size == sizeof(out)) flush();
        size_t room = sizeof(out) - out_size, take = n < room ? n : room;
        memcpy(out + out_size, s, take);
        out_size += take;
        s += take;
        n -= take;
    }
}
#define LITERAL(s) emit(s, sizeof(s) - 1)
static void number(uint64_t value, unsigned radix) {
    char buffer[32];
    size_t n = sizeof(buffer);
    do { buffer[--n] = "0123456789abcdef"[value % radix]; value /= radix; } while (value);
    emit(buffer + n, sizeof(buffer) - n);
}

// MARK: Reading the crashed thread (signal time)

static int safe_read(uintptr_t address, void *into, size_t size) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, size, (vm_address_t)into, &got) == KERN_SUCCESS
        && got == size;
}

// A return address without its pointer authentication code (none in an arm64 process; exact either way).
static uintptr_t strip(uintptr_t p) {
#if defined(__arm64__)
    __asm__ volatile("mov x30, %1\n\thint #7\n\tmov %0, x30" : "=r"(p) : "r"(p) : "x30");   // xpaclri
#endif
    return p;
}

static uintptr_t context_pc(const ucontext_t *uc) {
#if defined(__arm64__)
    return (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
#else
    return (uintptr_t)uc->uc_mcontext->__ss.__rip;
#endif
}

// The crash site, then the return addresses up the frame-pointer chain (the ABI keeps frame records on arm64). On
// arm64 the link register comes second: a leaf function (objc_msgSend, memcpy) has no frame record yet, and the frame
// it was called from would be lost; it is skipped when the chain's first return address repeats it.
static size_t walk(const ucontext_t *uc, uintptr_t *into, size_t max) {
    size_t n = 0;
    into[n++] = context_pc(uc);
#if defined(__arm64__)
    uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    uintptr_t lr = strip((uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
    if (lr && n < max) into[n++] = lr;
#else
    uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
    uintptr_t lr = 0;
#endif
    while (n < max && fp && (fp & 7) == 0) {
        uintptr_t record[2];
        if (!safe_read(fp, record, sizeof(record))) break;
        uintptr_t ret = strip(record[1]);
        if (!ret) break;
        if (!(n == 2 && lr && ret == lr)) into[n++] = ret;
        if (record[0] <= fp) break;   // callers' frames sit higher on the stack
        fp = record[0];
    }
    return n;
}

// MARK: The record (signal time)

static void write_record(int sig, const siginfo_t *info, const ucontext_t *uc) {
    if (record_fd < 0) return;
    out_fd = record_fd;
    struct timespec now = {0};
    clock_gettime(CLOCK_REALTIME, &now);
    emit(record_header, record_header_size);
    LITERAL("time "); number((uint64_t)now.tv_sec, 10);
    LITERAL("\nsignal "); number((uint64_t)sig, 10);
    LITERAL("\ncode "); number((uint32_t)info->si_code, 10);
    LITERAL("\nfault 0x"); number((uintptr_t)info->si_addr, 16);
    LITERAL("\n");
    flush();   // the signal is on disk before anything reads the stack
    size_t n = walk(uc, frames, kMaxFrames);
    uint32_t count = atomic_load_explicit(&image_count, memory_order_acquire);
    for (size_t i = 0; i < n; ++i) {
        LITERAL("frame 0x"); number(frames[i], 16); LITERAL("\n");
        for (uint32_t j = 0; j < count; ++j) {
            if (frames[i] - images[j].base < images[j].size) { used[j] = 1; break; }
        }
    }
    // Only the binaries the frames fall in, as in macOS's report.
    for (uint32_t j = 0; j < count; ++j) {
        if (!used[j]) continue;
        const struct image *m = &images[j];
        LITERAL("image 0x"); number(m->base, 16);
        LITERAL(" 0x"); number(m->size, 16);
        LITERAL(" "); emit(&m->origin, 1);
        LITERAL(" ");
        for (int b = 0; b < 16; ++b) {
            emit(&"0123456789ABCDEF"[m->uuid[b] >> 4], 1);
            emit(&"0123456789ABCDEF"[m->uuid[b] & 15], 1);
        }
        LITERAL(" "); emit(m->name, strnlen(m->name, sizeof(m->name)));
        LITERAL("\n");
    }
    LITERAL("end\n");
    flush();
}

// Crash.log (dev and test builds): the same facts for people, then execinfo's symbols. Darwin's symbolizer is best
// effort, not guaranteed async-signal-safe; the record is already written.
static void write_log(int sig, const siginfo_t *info, const ucontext_t *uc) {
    if (log_fd < 0) return;
    out_fd = log_fd;
    struct timespec now = {0};
    clock_gettime(CLOCK_REALTIME, &now);
    uintptr_t pc = context_pc(uc);
    LITERAL("Airc crash unix-time="); number((uint64_t)now.tv_sec, 10);
    LITERAL(" signal="); number((uint64_t)sig, 10);
    LITERAL(" code="); number((uint32_t)info->si_code, 10);
    LITERAL(" fault=0x"); number((uintptr_t)info->si_addr, 16);
    LITERAL(" pc=0x"); number(pc, 16);
    LITERAL("\n");
    emit(log_header, log_header_size);
    flush();
    void *symbols[96];
    symbols[0] = (void *)pc;
    backtrace_symbols_fd(symbols, 1, log_fd);
    int count = backtrace(symbols, 96);
    backtrace_symbols_fd(symbols, count, log_fd);
    LITERAL("end crash\n");
    flush();
}

// MARK: The handler

static int slot(int sig) {
    for (unsigned i = 0; i < SIGNAL_COUNT; ++i) if (kSignals[i] == sig) return (int)i;
    return -1;
}

static void crash(int sig, siginfo_t *info, void *context);

static int is_handler(const struct sigaction *a) {
    if (a->sa_flags & SA_SIGINFO) return a->sa_sigaction != NULL && a->sa_sigaction != crash;
    return a->sa_handler != SIG_DFL && a->sa_handler != SIG_IGN;
}

// Whether returning re-runs the faulting instruction. A signal that was raised or sent (abort, kill, raise) arrives as
// a system call returns, right after its supervisor call; it doesn't come back by itself.
static int recurs(int sig, const ucontext_t *uc) {
    if (sig == SIGABRT) return 0;
    uintptr_t pc = context_pc(uc);
#if defined(__arm64__)
    uint32_t instruction = 0;
    if (safe_read(pc - 4, &instruction, sizeof(instruction)) && instruction == 0xD4001001) return 0;   // svc #0x80
#elif defined(__x86_64__)
    uint16_t instruction = 0;
    if (safe_read(pc - 2, &instruction, sizeof(instruction)) && instruction == 0x050F) return 0;   // syscall
#endif
    return 1;
}

static void hand_on(int sig, const ucontext_t *uc) {
    int i = slot(sig);
    if (i >= 0 && is_handler(&previous[i])) sigaction(sig, &previous[i], NULL);
    else signal(sig, SIG_DFL);
    if (!recurs(sig, uc)) {
        // Pending until this handler returns; then it is delivered where it was raised.
        sigset_t set;
        sigemptyset(&set);
        sigaddset(&set, sig);
        pthread_sigmask(SIG_BLOCK, &set, NULL);
        raise(sig);
    }
}

static void crash(int sig, siginfo_t *info, void *context) {
    const ucontext_t *uc = context;
    int expected = 0;
    if (atomic_compare_exchange_strong(&claimed, &expected, 1)) {
        claimant = pthread_self();
        write_record(sig, info, uc);
        write_log(sig, info, uc);
        atomic_store(&finished, 1);
    } else if (!pthread_equal(claimant, pthread_self())) {
        // Another thread crashed first: let it finish (the process ends when it hands its signal on), 3 s at most.
        struct timespec pause = { 0, 10 * 1000 * 1000 };
        for (int i = 0; i < 300 && !atomic_load(&finished); ++i) nanosleep(&pause, NULL);
    }
    // Else writing faulted on this very thread (SA_NODEFER brought us back): hand the signal on at once.
    hand_on(sig, uc);
}

// MARK: Install (normal context)

static int has_prefix(const char *s, const char *prefix) {
    return prefix[0] && strncmp(s, prefix, strlen(prefix)) == 0;
}

// The UUID and __TEXT size from the load commands.
static int describe(const struct mach_header *mh, struct image *into) {
    if (mh->magic != MH_MAGIC_64) return 0;
    const uint8_t *cursor = (const uint8_t *)mh + sizeof(struct mach_header_64);
    int has_uuid = 0;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        const struct load_command *lc = (const void *)cursor;
        if (lc->cmd == LC_UUID) {
            memcpy(into->uuid, ((const struct uuid_command *)lc)->uuid, 16);
            has_uuid = 1;
        } else if (lc->cmd == LC_SEGMENT_64 && strncmp(((const struct segment_command_64 *)lc)->segname, "__TEXT", 16) == 0) {
            into->size = ((const struct segment_command_64 *)lc)->vmsize;
        }
        if (lc->cmdsize == 0) break;
        cursor += lc->cmdsize;
    }
    return has_uuid && into->size;
}

static void add_image_at(const struct mach_header *mh, const char *path) {
    struct image entry = { .base = (uintptr_t)mh };
    if (mh == main_header || has_prefix(path, bundle_prefix[0]) || has_prefix(path, bundle_prefix[1])) entry.origin = 'a';
    else if (has_prefix(path, "/System/") || has_prefix(path, "/usr/lib/") || has_prefix(path, "/Library/Apple/")) entry.origin = 's';
    else return;
    if (!describe(mh, &entry)) return;
    const char *slash = strrchr(path, '/');
    strlcpy(entry.name, slash ? slash + 1 : path, sizeof(entry.name));
    pthread_mutex_lock(&image_lock);
    uint32_t n = atomic_load_explicit(&image_count, memory_order_relaxed);
    if (n < kMaxImages) {
        images[n] = entry;
        atomic_store_explicit(&image_count, n + 1, memory_order_release);
    }
    pthread_mutex_unlock(&image_lock);
}

// dyld calls this for every binary already loaded when it is registered, then for each one loaded later.
static void add_image(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    Dl_info info;
    if (dladdr(mh, &info) && info.dli_fname) add_image_at(mh, info.dli_fname);
}

// A header value for the record: letters, digits and . _ - only (AircKit checks each field's format again).
static void header_field(const char *key, const char *value) {
    size_t room = sizeof(record_header) - record_header_size;
    int n = snprintf(record_header + record_header_size, room, "%s ", key);
    if (n < 0 || (size_t)n >= room) return;
    record_header_size += (size_t)n;
    const char *v = value ? value : "";
    for (const char *c = v; *c && record_header_size < sizeof(record_header) - 2 && c - v < 40; ++c) {
        int ok = (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '.' || *c == '_' || *c == '-';
        record_header[record_header_size++] = ok ? *c : '?';
    }
    record_header[record_header_size++] = '\n';
}

// Rotates `path`, `path.1` … `path.<keep>` when `path` holds a crash; an empty file from a clean run stays.
static void rotate(const char *path, int keep) {
    struct stat st;
    if (stat(path, &st) != 0 || st.st_size == 0) return;
    char from[PATH_MAX + 8], to[PATH_MAX + 8];
    for (int i = keep; i >= 1; --i) {
        snprintf(to, sizeof(to), "%s.%d", path, i);
        if (i == 1) snprintf(from, sizeof(from), "%s", path);
        else snprintf(from, sizeof(from), "%s.%d", path, i - 1);
        rename(from, to);
    }
}

static int open_private(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd >= 0) fchmod(fd, 0600);
    return fd;
}

static void install_handlers(void) {
    struct sigaction action = {0};
    action.sa_sigaction = crash;
    sigemptyset(&action.sa_mask);
    // SA_NODEFER: a fault while writing comes back here and is handed on, instead of hitting a blocked signal.
    action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    for (unsigned i = 0; i < SIGNAL_COUNT; ++i) {
        struct sigaction old;
        if (sigaction(kSignals[i], &action, &old) != 0) continue;
        // Installing again keeps what was there before us; anything installed since (Chromium's) comes next.
        if (!((old.sa_flags & SA_SIGINFO) && old.sa_sigaction == crash)) previous[i] = old;
    }
}

void airc_crash_install(const char *record_dir, const char *log_path, const char *bundle_path, const char *version,
                        const char *build, const char *os_version) {
    if (!installed) {
        installed = 1;
        main_header = _dyld_get_image_header(0);
        if (bundle_path && *bundle_path) {
            snprintf(bundle_prefix[0], sizeof(bundle_prefix[0]), "%s/", bundle_path);
            char resolved[PATH_MAX];
            if (realpath(bundle_path, resolved)) snprintf(bundle_prefix[1], sizeof(bundle_prefix[1]), "%s/", resolved);
        }
        _dyld_register_func_for_add_image(add_image);
        // dyld itself isn't in that list; every thread's outermost frame (start, thread_start's caller) is in it.
        struct task_dyld_info dyld_info;
        mach_msg_type_number_t dyld_info_count = TASK_DYLD_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyld_info, &dyld_info_count) == KERN_SUCCESS) {
            const struct dyld_all_image_infos *all = (const void *)(uintptr_t)dyld_info.all_image_info_addr;
            if (all && all->dyldImageLoadAddress) add_image_at(all->dyldImageLoadAddress, "/usr/lib/dyld");
        }

        if (record_dir) {
            char path[PATH_MAX];
            snprintf(path, sizeof(path), "%s/record", record_dir);
            rotate(path, kRecordsKept);
            record_fd = open_private(path);
            record_header_size = (size_t)snprintf(record_header, sizeof(record_header), "airc-crash-record 1\npid %d\n", getpid());
            header_field("version", version);
            header_field("build", build);
            header_field("os", os_version);
        }
        if (log_path) {
            rotate(log_path, 3);   // Crash.log plus the last three
            log_fd = open_private(log_path);
            log_header_size = (size_t)snprintf(log_header, sizeof(log_header), "build=%s\nimages (PC - base = image offset):\n", build ? build : "");
            for (uint32_t i = 0; i < _dyld_image_count() && log_header_size < sizeof(log_header) - 512; ++i) {
                const char *name = _dyld_get_image_name(i);
                const char *base = strrchr(name, '/');
                log_header_size += (size_t)snprintf(log_header + log_header_size, sizeof(log_header) - log_header_size,
                    "%p %.*s\n", (void *)_dyld_get_image_header(i), 240, base ? base + 1 : name);
            }
            // execinfo loads its symbolizer lazily: do that now, not in the handler.
            int sink = open("/dev/null", O_WRONLY | O_CLOEXEC);
            void *warm[8];
            int n = backtrace(warm, 8);
            if (sink >= 0) { backtrace_symbols_fd(warm, n, sink); close(sink); }
        }
        uintptr_t probe;
        safe_read((uintptr_t)&probe, &probe, sizeof(probe));   // the thread's MIG reply port, now
        stack_t stack = { .ss_sp = alternate_stack, .ss_size = sizeof(alternate_stack), .ss_flags = 0 };
        sigaltstack(&stack, NULL);
    }
    install_handlers();
}

int airc_crash_handlers_installed(void) {
    for (unsigned i = 0; i < SIGNAL_COUNT; ++i) {
        struct sigaction current;
        if (sigaction(kSignals[i], NULL, &current) != 0) return 0;
        if (!((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == crash)) return 0;
    }
    return 1;
}

int airc_crash_chained_handlers(void) {
    int n = 0;
    for (unsigned i = 0; i < SIGNAL_COUNT; ++i) n += is_handler(&previous[i]);
    return n;
}

int airc_crash_image_count(void) {
    return (int)atomic_load(&image_count);
}
