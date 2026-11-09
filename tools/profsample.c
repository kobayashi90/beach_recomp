// profsample.c -- hardware sampling profiler for a running process (no `perf` needed).
//
// Opens one sampling counter per thread with perf_event_open(2), mmaps the
// per-event ring buffer, and collects (ip, tid) pairs until the deadline.
// Output is one line per (ip, tid): "<count> <tid> <ip-hex>", sorted by count,
// which tools/profsym.py resolves against the process maps + ELF symbols.
//
// Why this exists: perf_event_paranoid=2 allows self/child sampling but the
// `perf` userland tool is not installed, and cycle/instruction totals (see
// perfcount.c) cannot tell WHICH generated chunk is eating the core. Sampling
// at 997 Hz for 30 s gives ~30k IPs, enough to rank the hot chunks.
//
// usage: profsample PID SECONDS [SAMPLE_HZ] [EVENT]
//   EVENT: cycles (default) | instructions | branches
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <linux/perf_event.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define MAXT 512
#define PERF_PAGE 4096
#define RING_PAGES 64

struct slot {
    uint64_t ip;
    uint32_t tid;
    uint64_t count;
};

static long perf_open(struct perf_event_attr *a, pid_t tid) {
    return syscall(__NR_perf_event_open, a, tid, -1, -1, 0);
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// Growable (ip, tid) table with linear probing; linear scan for the top list
// would be fine for a few thousand distinct IPs, but chunks give hundreds of
// thousands of distinct IPs once inner loops get inlined.
static struct slot *table;
static size_t table_cap, table_used;

static void table_init(size_t cap) {
    table_cap = cap;
    table_used = 0;
    table = calloc(table_cap, sizeof *table);
    if (!table) { perror("calloc"); exit(1); }
}

static void table_add(uint64_t ip, uint32_t tid) {
    size_t i = (size_t)((ip * 0x9E3779B97F4A7C15ull) >> 20) & (table_cap - 1);
    for (size_t probes = 0; probes < table_cap; probes++) {
        struct slot *s = &table[i];
        if (s->count == 0) {
            s->ip = ip;
            s->tid = tid;
            s->count = 1;
            table_used++;
            if (table_used * 10 >= table_cap * 7) {
                // Load factor too high: rehash into a table twice as large.
                struct slot *old = table;
                size_t old_cap = table_cap;
                table_init(old_cap * 2);
                for (size_t k = 0; k < old_cap; k++) {
                    if (!old[k].count)
                        continue;
                    table_add(old[k].ip, old[k].tid);
                    // table_add just inserted this pair with count 1; restore it.
                    size_t j = (size_t)((old[k].ip * 0x9E3779B97F4A7C15ull) >> 20) & (table_cap - 1);
                    while (!(table[j].ip == old[k].ip && table[j].tid == old[k].tid))
                        j = (j + 1) & (table_cap - 1);
                    table[j].count = old[k].count;
                }
                free(old);
                return;
            }
            return;
        }
        if (s->ip == ip && s->tid == tid) { s->count++; return; }
        i = (i + 1) & (table_cap - 1);
    }
}

static int cmp_desc(const void *a, const void *b) {
    const struct slot *x = a, *y = b;
    if (x->count != y->count) return x->count < y->count ? 1 : -1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: profsample PID SECONDS [SAMPLE_HZ] [cycles|instructions|branches]\n");
        return 1;
    }
    pid_t pid = atoi(argv[1]);
    double sec = atof(argv[2]);
    unsigned hz = argc > 3 ? (unsigned)atoi(argv[3]) : 997;
    if (!hz) hz = 997;
    uint64_t event = PERF_COUNT_HW_CPU_CYCLES;
    if (argc > 4) {
        if (!strcmp(argv[4], "instructions")) event = PERF_COUNT_HW_INSTRUCTIONS;
        else if (!strcmp(argv[4], "branches")) event = PERF_COUNT_HW_BRANCH_INSTRUCTIONS;
    }

    char path[64];
    snprintf(path, sizeof path, "/proc/%d/task", pid);
    DIR *d = opendir(path);
    if (!d) { perror("opendir"); return 1; }

    struct { pid_t tid; int fd; void *ring; size_t ring_len; uint64_t lost; } ev[MAXT];
    int nev = 0;
    struct dirent *e;
    while ((e = readdir(d)) && nev < MAXT) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        pid_t tid = atoi(e->d_name);

        struct perf_event_attr a;
        memset(&a, 0, sizeof a);
        a.size = sizeof a;
        a.type = PERF_TYPE_HARDWARE;
        a.config = event;
        a.sample_freq = hz;
        a.freq = 1;
        a.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID;
        a.disabled = 1;
        a.exclude_kernel = 1;
        a.exclude_hv = 1;
        a.wakeup_events = 1;
        int fd = (int)perf_open(&a, tid);
        if (fd < 0) continue;

        size_t len = (1 + RING_PAGES) * PERF_PAGE;
        void *ring = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ring == MAP_FAILED) { close(fd); continue; }
        ev[nev].tid = tid;
        ev[nev].fd = fd;
        ev[nev].ring = ring;
        ev[nev].ring_len = len;
        ev[nev].lost = 0;
        nev++;
    }
    closedir(d);
    if (!nev) { fprintf(stderr, "no sampling events opened (%s)\n", strerror(errno)); return 1; }

    for (int i = 0; i < nev; i++) ioctl(ev[i].fd, PERF_EVENT_IOC_ENABLE, 0);

    table_init(1u << 18);
    uint64_t samples = 0, lost_total = 0;
    struct pollfd pfds[MAXT];
    for (int i = 0; i < nev; i++) { pfds[i].fd = ev[i].fd; pfds[i].events = POLLIN; }

    uint64_t deadline = now_ns() + (uint64_t)(sec * 1e9);
    while (now_ns() < deadline) {
        int left = (int)((deadline - now_ns()) / 1000000ull);
        if (left > 200) left = 200;
        if (left < 1) break;
        if (poll(pfds, (nfds_t)nev, left) < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            break;
        }
        for (int i = 0; i < nev; i++) {
            if (!(pfds[i].revents & POLLIN)) continue;
            struct perf_event_mmap_page *meta = ev[i].ring;
            uint64_t head = meta->data_head;
            __sync_synchronize();
            uint64_t tail = meta->data_tail;
            uint8_t *base = (uint8_t *)ev[i].ring + meta->data_offset;
            uint64_t size = meta->data_size;
            while (tail < head) {
                struct perf_event_header hdr;
                uint64_t off = tail % size;
                // Header may straddle the ring end.
                uint8_t *hp = base + off;
                if (off + sizeof hdr > size) {
                    uint8_t tmp[sizeof hdr];
                    size_t first = size - off;
                    memcpy(tmp, hp, first);
                    memcpy(tmp + first, base, sizeof hdr - first);
                    memcpy(&hdr, tmp, sizeof hdr);
                } else {
                    memcpy(&hdr, hp, sizeof hdr);
                }
                if (hdr.size < sizeof hdr) break;
                if (hdr.type == PERF_RECORD_SAMPLE) {
                    uint8_t tmp[64];
                    if (off + hdr.size > size) {
                        size_t first = size - off;
                        if (hdr.size <= sizeof tmp) {
                            memcpy(tmp, hp, first);
                            memcpy(tmp + first, base, hdr.size - first);
                        }
                    } else if (hdr.size <= sizeof tmp) {
                        memcpy(tmp, hp, hdr.size);
                    }
                    // PERF_SAMPLE_IP then PERF_SAMPLE_TID (pid, tid).
                    uint64_t ip;
                    uint32_t tid;
                    memcpy(&ip, tmp + sizeof hdr, 8);
                    memcpy(&tid, tmp + sizeof hdr + 12, 4);
                    table_add(ip, tid);
                    samples++;
                } else if (hdr.type == PERF_RECORD_LOST) {
                    uint64_t lost;
                    memcpy(&lost, (uint8_t *)base + ((tail + sizeof hdr) % size), 8);
                    ev[i].lost += lost;
                    lost_total += lost;
                }
                tail += hdr.size;
            }
            meta->data_tail = head;
        }
    }

    for (int i = 0; i < nev; i++) {
        ioctl(ev[i].fd, PERF_EVENT_IOC_DISABLE, 0);
        munmap(ev[i].ring, ev[i].ring_len);
        close(ev[i].fd);
    }

    qsort(table, table_cap, sizeof *table, cmp_desc);

    fprintf(stderr, "profsample: %d threads, %llu samples, %llu lost, %zu distinct (ip,tid)\n",
            nev, (unsigned long long)samples, (unsigned long long)lost_total, table_used);
    for (size_t i = 0; i < table_cap && table[i].count; i++)
        printf("%llu %u 0x%llx\n", (unsigned long long)table[i].count, table[i].tid,
               (unsigned long long)table[i].ip);
    return 0;
}
