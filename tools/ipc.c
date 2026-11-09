// ipc.c -- IPC and instruction-fetch health for ONE thread.
//
// "The CPU thread is at 99 % of a core" does not say whether it is doing work or
// waiting for instructions. A big recompiled module (one 16 KB guest region
// compiles to ~730 KB of host code) can be limited by instruction fetch rather
// than by execution, and the two need opposite fixes:
//
//   IPC >= ~1.2 with low L1I miss rate  -> executing, needs less work (codegen)
//   IPC <= ~0.7 or high L1I miss rate   -> fetching, needs smaller/denser code
//
// usage: ipc TID [seconds]
#define _GNU_SOURCE
#include <linux/perf_event.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

static long pe(struct perf_event_attr *a, pid_t tid, int group) {
    return syscall(__NR_perf_event_open, a, tid, -1, group, 0);
}

static int open_hw(pid_t tid, __u64 cfg, int group) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = PERF_TYPE_HARDWARE;
    a.config = cfg;
    a.disabled = (group < 0);
    a.exclude_kernel = 1;
    a.exclude_hv = 1;
    if (group < 0)
        a.read_format = PERF_FORMAT_GROUP;  // group leader returns every member
    return (int)pe(&a, tid, group);
}

static int open_l1i(pid_t tid, int group) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = PERF_TYPE_HW_CACHE;
    a.config = PERF_COUNT_HW_CACHE_L1I |
               (PERF_COUNT_HW_CACHE_OP_READ << 8) |
               (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
    a.disabled = 0;
    a.exclude_kernel = 1;
    a.exclude_hv = 1;
    return (int)pe(&a, tid, group);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: ipc TID [sec]\n"); return 1; }
    const pid_t tid = atoi(argv[1]);
    const double sec = argc > 2 ? atof(argv[2]) : 3.0;

    const int cyc = open_hw(tid, PERF_COUNT_HW_CPU_CYCLES, -1);
    if (cyc < 0) { perror("cycles"); return 2; }
    const int ins = open_hw(tid, PERF_COUNT_HW_INSTRUCTIONS, cyc);
    const int br = open_hw(tid, PERF_COUNT_HW_BRANCH_MISSES, cyc);
    const int l1i = open_l1i(tid, cyc);
    if (ins < 0 || br < 0 || l1i < 0) { perror("group"); return 2; }

    ioctl(cyc, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
    ioctl(cyc, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
    usleep((useconds_t)(sec * 1e6));
    ioctl(cyc, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);

    // group read layout: { u64 nr; u64 value[nr]; }
    struct { unsigned long long nr; unsigned long long v[4]; } f;
    const ssize_t got = read(cyc, &f, sizeof f.nr + 4 * sizeof f.v[0]);
    if (got < (ssize_t)(sizeof f.nr + 4 * sizeof f.v[0])) {
        fprintf(stderr, "read returned %zd (nr=%llu)\n", got, f.nr);
        return 2;
    }

    const unsigned long long cycles = f.v[0], instr = f.v[1], brmiss = f.v[2], imiss = f.v[3];
    if (!cycles) { printf("no cycles counted (thread idle?)\n"); return 0; }
    printf("  cycles %.3f G   instructions %.3f G   IPC %.3f\n",
           cycles / 1e9, instr / 1e9, (double)instr / (double)cycles);
    printf("  L1I miss %.2f /kinst   branch miss %.2f /kinst (%5.2f%%)\n",
           1000.0 * imiss / instr, 1000.0 * brmiss / instr, 100.0 * brmiss / instr);
    if ((double)instr / (double)cycles < 0.8 || 1000.0 * imiss / instr > 20.0)
        printf("  verdict: FETCH BOUND - the win is smaller/denser host code\n");
    else
        printf("  verdict: EXECUTION BOUND - the win is fewer host instructions\n");
    return 0;
}
