// Process-wide hardware counter reader via perf_event_open(2).
// Opens one counter group per thread in /proc/PID/task and sums them.
// usage: perfcount PID [seconds]
#define _GNU_SOURCE
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <dirent.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

#define MAXT 256

static long pe(struct perf_event_attr *a, pid_t tid, int group_fd) {
    return syscall(__NR_perf_event_open, a, tid, -1, group_fd, 0);
}

static long open_ev(pid_t tid, __u64 cfg, int group) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size = sizeof a;
    a.type = PERF_TYPE_HARDWARE;
    a.config = cfg;
    a.disabled = (group < 0);      // only the leader starts disabled
    a.exclude_kernel = 1;
    a.exclude_hv = 1;
    a.read_format = (group < 0) ? PERF_FORMAT_GROUP : 0;
    return pe(&a, tid, group);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: perfcount PID [sec]\n"); return 1; }
    pid_t pid = atoi(argv[1]);
    double sec = argc > 2 ? atof(argv[2]) : 3.0;

    char path[64];
    snprintf(path, sizeof path, "/proc/%d/task", pid);
    DIR *d = opendir(path);
    if (!d) { perror("opendir"); return 1; }

    pid_t tids[MAXT];
    int ntid = 0;
    struct dirent *e;
    while ((e = readdir(d)) && ntid < MAXT) {
        if (e->d_name[0] >= '0' && e->d_name[0] <= '9')
            tids[ntid++] = atoi(e->d_name);
    }
    closedir(d);

    long leaders[MAXT];
    int nl = 0;
    for (int i = 0; i < ntid; i++) {
        long fc = open_ev(tids[i], PERF_COUNT_HW_CPU_CYCLES, -1);
        if (fc < 0) continue;
        long fi = open_ev(tids[i], PERF_COUNT_HW_INSTRUCTIONS, (int)fc);
        long fb = open_ev(tids[i], PERF_COUNT_HW_BRANCH_INSTRUCTIONS, (int)fc);
        long fm = open_ev(tids[i], PERF_COUNT_HW_BRANCH_MISSES, (int)fc);
        if (fi < 0 || fb < 0 || fm < 0) {
            fprintf(stderr, "tid %d member open failed: %s\n", tids[i], strerror(errno));
            close(fc); continue;
        }
        leaders[nl++] = fc;
    }
    if (!nl) { fprintf(stderr, "no events opened\n"); return 1; }

    for (int i = 0; i < nl; i++) {
        ioctl(leaders[i], PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
        ioctl(leaders[i], PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
    }
    usleep((useconds_t)(sec * 1e6));
    for (int i = 0; i < nl; i++)
        ioctl(leaders[i], PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);

    double cyc = 0, ins = 0, br = 0, miss = 0;
    for (int i = 0; i < nl; i++) {
        struct { __u64 nr; __u64 v[4]; } grp;
        memset(&grp, 0, sizeof grp);
        if (read(leaders[i], &grp, sizeof grp) == (ssize_t)sizeof grp && grp.nr == 4) {
            cyc += (double)grp.v[0];
            ins += (double)grp.v[1];
            br  += (double)grp.v[2];
            miss += (double)grp.v[3];
        }
        close(leaders[i]);
    }

    printf("threads      : %d opened, %d counted\n", ntid, nl);
    printf("seconds      : %.1f\n", sec);
    printf("cycles       : %.3f G  (%.0f M/s)\n", cyc / 1e9, cyc / sec / 1e6);
    printf("instructions : %.3f G  (%.0f M/s)\n", ins / 1e9, ins / sec / 1e6);
    printf("IPC          : %.3f\n", ins / cyc);
    printf("branches     : %.3f G  misses=%.3f M (%.2f%%)\n",
           br / 1e9, miss / 1e6, br ? 100.0 * miss / br : 0.0);
    return 0;
}
