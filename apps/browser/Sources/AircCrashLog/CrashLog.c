// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "AircCrashLog.h"
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

static int crash_fd = -1;
static char header[65536];
static size_t header_size;
static volatile sig_atomic_t handling;
static char alternate_stack[65536];

static void put(const char *s, size_t n) {
    while (n) {
        ssize_t count = write(crash_fd, s, n);
        if (count <= 0) break;
        s += count;
        n -= (size_t)count;
    }
}
#define LITERAL(s) put(s, sizeof(s) - 1)
static void number(uint64_t value, unsigned radix) {
    char buffer[32];
    size_t n = sizeof(buffer);
    do { buffer[--n] = "0123456789abcdef"[value % radix]; value /= radix; } while (value);
    put(buffer + n, sizeof(buffer) - n);
}
static void crash(int sig, siginfo_t *info, void *context) {
    if (!handling) {
        handling = 1;
        // This header is written before unwinding: even a corrupt heap/unwinder leaves the fault PC.
        struct timespec now = {0};
        clock_gettime(CLOCK_REALTIME, &now);
        LITERAL("Airc crash unix-time="); number(now.tv_sec, 10);
        LITERAL(" signal="); number(sig, 10);
        LITERAL(" code="); number((uint32_t)info->si_code, 10);
        LITERAL(" fault=0x"); number((uintptr_t)info->si_addr, 16);
        LITERAL(" pc=0x");
        ucontext_t *uc = context;
#if defined(__arm64__)
        uintptr_t pc = uc->uc_mcontext->__ss.__pc;
#else
        uintptr_t pc = uc->uc_mcontext->__ss.__rip;
#endif
        number(pc, 16); LITERAL("\n");
        put(header, header_size);
        // Darwin's execinfo symbolizer is best effort, not guaranteed async-signal-safe. It can
        // fail for allocator corruption. No Foundation, Swift, page state or general stderr here.
        // Prewarm below, and preserve the raw PC + image bases before calling it.
        void *frames[96];
        frames[0] = (void *)pc;
        backtrace_symbols_fd(frames, 1, crash_fd);
        int count = backtrace(frames, 96);
        backtrace_symbols_fd(frames, count, crash_fd);
        LITERAL("end crash\n");
    }
    // Restore default disposition and deliver the original fatal signal, including under a debugger.
    signal(sig, SIG_DFL);
    sigset_t set;
    sigemptyset(&set); sigaddset(&set, sig);
    sigprocmask(SIG_UNBLOCK, &set, NULL);
    raise(sig);
    _exit(128 + sig);
}

void airc_crash_log_install(const char *path, const char *build) {
    if (crash_fd < 0) {
        // Only rotate a report, never an empty file left by a clean launch. Last four crashes.
        struct stat st;
        if (stat(path, &st) == 0 && st.st_size > 0) {
            char from[4096], to[4096];
            for (int i = 3; i >= 1; --i) {
                snprintf(to, sizeof(to), "%s.%d", path, i);
                if (i == 1) snprintf(from, sizeof(from), "%s", path);
                else snprintf(from, sizeof(from), "%s.%d", path, i - 1);
                rename(from, to);
            }
        }
        crash_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (crash_fd < 0) return;
        fchmod(crash_fd, 0600);
        header_size = (size_t)snprintf(header, sizeof(header), "build=%s\nimages (PC - base = image offset):\n", build);
        for (uint32_t i = 0; i < _dyld_image_count() && header_size < sizeof(header) - 512; ++i) {
            const char *name = _dyld_get_image_name(i);
            const char *base = strrchr(name, '/');
            header_size += (size_t)snprintf(header + header_size, sizeof(header) - header_size,
                "%p %.*s\n", (void *)_dyld_get_image_header(i), 240, base ? base + 1 : name);
        }
        int sink = open("/dev/null", O_WRONLY);
        void *frames[8]; int n = backtrace(frames, 8);
        if (sink >= 0) { backtrace_symbols_fd(frames, n, sink); close(sink); }
        stack_t stack = { .ss_sp = alternate_stack, .ss_size = sizeof(alternate_stack), .ss_flags = 0 };
        sigaltstack(&stack, NULL);
    }
    struct sigaction action = {0};
    action.sa_sigaction = crash;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE };
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) sigaction(signals[i], &action, NULL);
}
