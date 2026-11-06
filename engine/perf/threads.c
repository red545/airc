// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Owned-process thread CPU deltas without task_for_pid, sample or spindump.
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  int pid = atoi(argv[1]);
  uint64_t ids[4096];
  int bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, ids, sizeof(ids));
  if (bytes <= 0 || bytes == sizeof(ids)) return 1;
  for (int i = 0; i < bytes / sizeof(ids[0]); ++i) {
    struct proc_threadinfo t = {0};
    if (proc_pidinfo(pid, PROC_PIDTHREADINFO, ids[i], &t, sizeof(t)) != sizeof(t)) continue;
    // proc_threadinfo times are nanoseconds (unlike proc_pid_rusage's Mach ticks).
    printf("%llu\t%llu\t%llu\t%s\n", ids[i], t.pth_user_time, t.pth_system_time, t.pth_name);
  }
}
