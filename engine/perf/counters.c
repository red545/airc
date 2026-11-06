// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// No task_for_pid entitlement or sudo: kernel ledger counters for owned processes.
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  for (int i = 1; i < argc; ++i) {
    int pid = atoi(argv[i]);
    struct rusage_info_v4 r = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&r)) return 1;
    // task_power_info CPU totals are Mach absolute units (not ns on arm64).
    printf("{\"pid\":%d,\"start\":%llu,\"footprint\":%llu,\"cpu_ns\":%llu,\"timebase_numer\":%u,\"timebase_denom\":%u,"
           "\"interrupt_wakeups\":%llu,\"package_idle_wakeups\":%llu,\"disk_written\":%llu}\n",
           pid, r.ri_proc_start_abstime, r.ri_phys_footprint,
           (unsigned long long)(((__uint128_t)r.ri_user_time + r.ri_system_time) * tb.numer / tb.denom), tb.numer, tb.denom, r.ri_interrupt_wkups,
           r.ri_pkg_idle_wkups, r.ri_diskio_byteswritten);
  }
}
