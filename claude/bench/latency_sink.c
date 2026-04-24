/* latency_sink: connect to relay sink port, read COUNT messages of MSG_SIZE
 * bytes each, decode the embedded timestamp, compute receive latency, and
 * report p50/p90/p99/p99.9/max in microseconds.
 *
 * Usage: latency_sink HOST PORT COUNT [MSG_SIZE]
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

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s HOST PORT COUNT [MSG_SIZE]\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = atoi(argv[2]);
    long count = atol(argv[3]);
    long msg_size = (argc >= 5) ? atol(argv[4]) : 64;
    if (msg_size < 16) msg_size = 16;

    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) { perror("inet_pton"); return 1; }
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { perror("connect"); return 1; }

    uint8_t *buf = malloc((size_t)msg_size);
    uint64_t *lat_ns = malloc((size_t)count * sizeof(uint64_t));
    if (!buf || !lat_ns) { perror("malloc"); return 1; }

    long got_msgs = 0;
    long off = 0;
    while (got_msgs < count) {
        ssize_t r = read(fd, buf + off, msg_size - off);
        if (r == 0) break;
        if (r < 0) { perror("read"); break; }
        off += r;
        if (off == msg_size) {
            uint64_t recv_ts = now_ns();
            uint64_t send_ts;
            memcpy(&send_ts, buf + 8, 8);
            lat_ns[got_msgs++] = recv_ts - send_ts;
            off = 0;
        }
    }
    close(fd);

    if (got_msgs == 0) {
        fprintf(stderr, "latency_sink: no messages received\n");
        return 1;
    }

    qsort(lat_ns, got_msgs, sizeof(uint64_t), cmp_u64);
    uint64_t p50  = lat_ns[(long)(got_msgs * 0.50)];
    uint64_t p90  = lat_ns[(long)(got_msgs * 0.90)];
    uint64_t p99  = lat_ns[(long)(got_msgs * 0.99)];
    uint64_t p999 = lat_ns[(long)(got_msgs * 0.999)];
    uint64_t pmax = lat_ns[got_msgs - 1];
    uint64_t pmin = lat_ns[0];

    fprintf(stderr,
        "latency_sink: got=%ld/%ld min=%.1fus p50=%.1fus p90=%.1fus p99=%.1fus p999=%.1fus max=%.1fus\n",
        got_msgs, count,
        pmin / 1000.0, p50 / 1000.0, p90 / 1000.0,
        p99 / 1000.0, p999 / 1000.0, pmax / 1000.0);

    free(buf);
    free(lat_ns);
    return (got_msgs == count) ? 0 : 1;
}
