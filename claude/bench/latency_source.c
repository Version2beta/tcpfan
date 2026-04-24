/* latency_source: connect to relay source port, send N small timestamped
 * messages spaced by INTERVAL_US microseconds. Each message is exactly
 * MSG_SIZE bytes; the first 16 bytes are a uint64 sequence number then
 * a CLOCK_MONOTONIC nanosecond timestamp.
 *
 * Usage: latency_source HOST PORT COUNT INTERVAL_US [MSG_SIZE]
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

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s HOST PORT COUNT INTERVAL_US [MSG_SIZE]\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = atoi(argv[2]);
    long count = atol(argv[3]);
    long interval_us = atol(argv[4]);
    long msg_size = (argc >= 6) ? atol(argv[5]) : 64;
    if (msg_size < 16) msg_size = 16;

    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) { perror("inet_pton"); return 1; }
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { perror("connect"); return 1; }

    uint8_t *buf = calloc(1, msg_size);
    if (!buf) { perror("calloc"); return 1; }

    uint64_t t0 = now_ns();
    for (long i = 0; i < count; i++) {
        uint64_t seq = (uint64_t)i;
        uint64_t ts = now_ns();
        memcpy(buf, &seq, 8);
        memcpy(buf + 8, &ts, 8);
        long off = 0;
        while (off < msg_size) {
            ssize_t w = send(fd, buf + off, msg_size - off, 0);
            if (w < 0) { perror("send"); free(buf); close(fd); return 1; }
            off += w;
        }
        if (interval_us > 0 && i + 1 < count) {
            uint64_t target = t0 + (uint64_t)(i + 1) * (uint64_t)interval_us * 1000ULL;
            uint64_t now = now_ns();
            if (target > now) {
                struct timespec sl = {
                    .tv_sec  = (target - now) / 1000000000ULL,
                    .tv_nsec = (target - now) % 1000000000ULL,
                };
                nanosleep(&sl, NULL);
            }
        }
    }

    shutdown(fd, SHUT_WR);
    char drain[256];
    while (read(fd, drain, sizeof drain) > 0) {}
    close(fd);
    free(buf);
    fprintf(stderr, "latency_source: sent count=%ld msg_size=%ld interval_us=%ld\n",
            count, msg_size, interval_us);
    return 0;
}
