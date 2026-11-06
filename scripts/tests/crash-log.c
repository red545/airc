// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Standalone, no GUI, profile, Keychain or device access. Pass an empty scratch directory.
#include "AircCrashLog.h"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

__attribute__((noinline)) void crash_log_test_fault(int sig) { raise(sig); }
int main(int argc, char **argv) {
    assert(argc == 2);
    char path[4096]; snprintf(path, sizeof(path), "%s/Crash.log", argv[1]);
    const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        pid_t child = fork(); assert(child >= 0);
        if (!child) { airc_crash_log_install(path, "test-build"); airc_crash_log_install(path, "test-build"); crash_log_test_fault(signals[i]); _exit(99); }
        int status; assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == signals[i]);
        FILE *f = fopen(path, "r"); assert(f);
        char text[100000] = {0}; fread(text, 1, sizeof(text)-1, f); fclose(f);
        assert(strstr(text, "build=test-build") && strstr(text, "fault=0x") && strstr(text, "pc=0x"));
        assert(strstr(text, "crash_log_test_fault") && strstr(text, "end crash"));
        struct stat st; assert(stat(path, &st) == 0 && (st.st_mode & 0777) == 0600);
        printf("PASS signal %d: stack, metadata, private file, original fatal signal\n", signals[i]);
    }
    char rotated[4096]; snprintf(rotated, sizeof(rotated), "%s.3", path); assert(access(rotated, F_OK) == 0);
    snprintf(rotated, sizeof(rotated), "%s.4", path); assert(access(rotated, F_OK) != 0);
    puts("PASS retention: current plus three previous crash logs");
}
