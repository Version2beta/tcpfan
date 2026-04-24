/* source_writer: connect to host:port and push N bytes of deterministic data.
 * Optional pacing can enforce an average source bit-rate.
 *
 * Usage: source_writer HOST PORT BYTES [--rate-bps BITS_PER_SEC]
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* xorshift64* — deterministic data, seed fixed so sinks can verify. */
static uint64_t xs_state;
static uint64_t xs_next(void) {
    uint64_t x = xs_state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    xs_state = x;
    return x * 2685821657736338717ULL;
}

int main(int argc, char **argv) {
    if (!(argc == 4 || argc == 6)) {
        fprintf(stderr, "usage: %s HOST PORT BYTES [--rate-bps BITS_PER_SEC]\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = atoi(argv[2]);
    long long total = atoll(argv[3]);
    unsigned long long rate_bps = 0;

    if (argc == 6) {
        if (strcmp(argv[4], "--rate-bps") != 0) {
            fprintf(stderr, "unknown option: %s\n", argv[4]);
            return 2;
        }
        rate_bps = strtoull(argv[5], NULL, 10);
        if (rate_bps == 0) {
            fprintf(stderr, "invalid --rate-bps: %s\n", argv[5]);
            return 2;
        }
    }

    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    int sndbuf = 1 << 20; setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf);

    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) { perror("inet_pton"); return 1; }
    if (connect(fd, (struct sockaddr*)&sa, sizeof sa) < 0) { perror("connect"); return 1; }

    xs_state = 0xC0FFEE12345ULL;

    enum { CHUNK = 1 << 16 };
    uint8_t *buf = malloc(CHUNK);
    long long sent = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    while (sent < total) {
        long long want = total - sent;
        if (want > CHUNK) want = CHUNK;
        for (long long i = 0; i < want; i += 8) {
            uint64_t v = xs_next();
            long long n = want - i; if (n > 8) n = 8;
            memcpy(buf + i, &v, n);
        }
        long long off = 0;
        while (off < want) {
            ssize_t w = send(fd, buf + off, want - off, 0);
            if (w < 0) { perror("send"); free(buf); close(fd); return 1; }
            off += w;
        }
        sent += want;

        if (rate_bps > 0) {
            double target_sec = (double)(sent * 8.0) / (double)rate_bps;
            for (;;) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                double elapsed = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
                double sleep_s = target_sec - elapsed;
                if (sleep_s <= 0.0) break;
                if (sleep_s > 0.050) sleep_s = 0.050;

                struct timespec ts;
                ts.tv_sec = (time_t)sleep_s;
                ts.tv_nsec = (long)((sleep_s - (double)ts.tv_sec) * 1e9);
                nanosleep(&ts, NULL);
            }
        }
    }

    /* Half-close write side so relay sees EOF. */
    shutdown(fd, SHUT_WR);
    /* Drain any reverse data (should be zero). */
    char drain[4096];
    while (read(fd, drain, sizeof drain) > 0) {}
    close(fd);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    fprintf(stderr, "source: sent=%lld bytes in %.3fs => %.2f MiB/s\n",
            sent, dt, sent / dt / (1024.0 * 1024.0));
    free(buf);
    return 0;
}
