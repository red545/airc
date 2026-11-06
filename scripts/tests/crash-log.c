// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Standalone, no GUI, profile, Keychain or device access. Pass an empty scratch directory.
//   clang -I apps/browser/Sources/AircCrashLog/include apps/browser/Sources/AircCrashLog/CrashLog.c \
//     scripts/tests/crash-log.c -o crash-log-test && ./crash-log-test "$(mktemp -d)"
// Each case crashes a forked child and checks, from the parent (same addresses: fork), the signal record (signal,
// frames inside the crashing function, this binary with its UUID, `end`), Crash.log, the original signal as the exit
// status, the earlier handler run after ours, private files, and that the last three records are kept.
#include "AircCrashLog.h"
#include <assert.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char marker[4096];
// Like Chromium's stack dumper: notes the signal, restores the default action and returns, so the fault recurs.
static void earlier_handler(int sig) {
    int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { write(fd, "earlier\n", 8); close(fd); }
    signal(sig, SIG_DFL);
}

__attribute__((noinline)) void crash_log_test_fault(int sig) { raise(sig); __asm__ volatile(""); }
__attribute__((noinline)) void crash_log_test_segv(int sig) { (void)sig; *(volatile int *)16 = 1; __asm__ volatile(""); }
__attribute__((noinline)) void crash_log_test_abort(int sig) { (void)sig; abort(); }
static void *thread_main(void *arg) { crash_log_test_segv(0); return arg; }
__attribute__((noinline)) void crash_log_test_thread(int sig) {
    (void)sig;
    pthread_t t;
    pthread_create(&t, NULL, thread_main, NULL);
    pthread_join(t, NULL);
}

static void read_file(const char *path, char *into, size_t size) {
    memset(into, 0, size);
    FILE *f = fopen(path, "r");
    assert(f);
    fread(into, 1, size - 1, f);
    fclose(f);
}

// Some `frame 0x…` line of the record falls in [fn, fn + 96).
static int has_frame_in(const char *record, void *fn) {
    uintptr_t lo = (uintptr_t)fn, hi = lo + 96;
    for (const char *p = strstr(record, "frame 0x"); p; p = strstr(p + 1, "frame 0x")) {
        uintptr_t a = (uintptr_t)strtoull(p + 8, NULL, 16);
        if (a >= lo && a < hi) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    char records[4096], record[4096], log[4096], text[200000];
    snprintf(records, sizeof(records), "%s/CrashRecords", argv[1]);
    snprintf(record, sizeof(record), "%s/record", records);
    snprintf(log, sizeof(log), "%s/Crash.log", argv[1]);
    snprintf(marker, sizeof(marker), "%s/earlier", argv[1]);
    mkdir(records, 0700);
    struct { int sig; void (*crash)(int); int chained; const char *what; } cases[] = {
        {SIGSEGV, crash_log_test_fault, 0, "raised SIGSEGV"}, {SIGBUS, crash_log_test_fault, 0, "raised SIGBUS"},
        {SIGILL, crash_log_test_fault, 0, "raised SIGILL"}, {SIGABRT, crash_log_test_fault, 0, "raised SIGABRT"},
        {SIGTRAP, crash_log_test_fault, 0, "raised SIGTRAP"}, {SIGFPE, crash_log_test_fault, 0, "raised SIGFPE"},
        {SIGSEGV, crash_log_test_segv, 0, "a real fault"}, {SIGSEGV, crash_log_test_segv, 1, "a real fault, chained"},
        {SIGABRT, crash_log_test_abort, 1, "abort(), chained"}, {SIGSEGV, crash_log_test_thread, 0, "a fault on another thread"},
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        unlink(marker);
        fflush(stdout);   // abort() flushes stdio: not this process's lines
        pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            if (cases[i].chained) signal(cases[i].sig, earlier_handler);
            airc_crash_install(records, log, "/nonexistent/Airc.app", "0.1.0", "202611061714", "26.6");
            airc_crash_install(records, log, "/nonexistent/Airc.app", "0.1.0", "202611061714", "26.6");   // after Chromium
            assert(airc_crash_handlers_installed());
            assert(airc_crash_chained_handlers() == cases[i].chained);
            assert(airc_crash_image_count() > 10);
            cases[i].crash(cases[i].sig);
            _exit(99);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == cases[i].sig);
        read_file(record, text, sizeof(text));
        char want[64];
        snprintf(want, sizeof(want), "\nsignal %d\n", cases[i].sig);
        assert(strncmp(text, "airc-crash-record 1\npid ", 24) == 0);
        assert(strstr(text, "\nversion 0.1.0\nbuild 202611061714\nos 26.6\ntime ") && strstr(text, want));
        assert(strstr(text, "\nfault 0x") && strstr(text, "\nend\n"));
        assert(has_frame_in(text, (void *)cases[i].crash) || has_frame_in(text, (void *)crash_log_test_segv));
        assert(strstr(text, " a ") && strstr(text, " crash-log-test\n"));   // this binary: Airc's own, with a UUID
        if (cases[i].crash != crash_log_test_segv)                          // raised in the system's binaries
            assert(strstr(text, " s ") && strstr(text, "libsystem_"));
        assert(!strstr(text, "/Users/") && !strstr(text, "/private/") && !strstr(text, argv[1]));
        struct stat st;
        assert(stat(record, &st) == 0 && (st.st_mode & 0777) == 0600);
        read_file(log, text, sizeof(text));
        assert(strstr(text, "build=202611061714") && strstr(text, "fault=0x") && strstr(text, "pc=0x") && strstr(text, "end crash"));
        assert(stat(log, &st) == 0 && (st.st_mode & 0777) == 0600);
        assert((access(marker, F_OK) == 0) == (cases[i].chained != 0));
        printf("PASS %s (signal %d): record, Crash.log, private files, original signal%s\n", cases[i].what, cases[i].sig,
               cases[i].chained ? ", then the earlier handler" : "");
    }
    // A clean run leaves an empty record, which the next launch doesn't rotate.
    pid_t clean = fork();
    if (!clean) { airc_crash_install(records, NULL, "/nonexistent/Airc.app", "0.1.0", "202611061714", "26.6"); _exit(0); }
    int status;
    waitpid(clean, &status, 0);
    struct stat st;
    assert(stat(record, &st) == 0 && st.st_size == 0);
    char kept[4200];
    for (int i = 1; i <= 3; ++i) { snprintf(kept, sizeof(kept), "%s.%d", record, i); assert(access(kept, F_OK) == 0); }
    snprintf(kept, sizeof(kept), "%s.4", record);
    assert(access(kept, F_OK) != 0);
    puts("PASS retention: the last three crash records, an empty record after a clean run");
}
