/* sink_reader: connect to host:port, drain bytes, verify against the same
 * deterministic stream produced by source_writer. Print received count.
 *
 * Usage: sink_reader HOST PORT EXPECTED_BYTES [--no-verify]
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

static uint64_t xs_state;
static uint64_t xs_next(void) {
    uint64_t x = xs_state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    xs_state = x;
    return x * 2685821657736338717ULL;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s HOST PORT EXPECTED [--no-verify]\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = atoi(argv[2]);
    long long expected = atoll(argv[3]);
    int verify = !(argc >= 5 && strcmp(argv[4], "--no-verify") == 0);

    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    int rcvbuf = 1 << 20; setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);

    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) { perror("inet_pton"); return 1; }
    if (connect(fd, (struct sockaddr*)&sa, sizeof sa) < 0) { perror("connect"); return 1; }

    xs_state = 0xC0FFEE12345ULL;
    enum { CHUNK = 1 << 16 };
    uint8_t *buf = malloc(CHUNK);
    uint8_t *expect = malloc(CHUNK);

    long long got = 0;
    long long mismatches = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Verify byte-by-byte against the deterministic xorshift stream. We
     * keep the most recent 8-byte word in a small carry buffer and consume
     * bytes from it as data arrives, regardless of read alignment. */
    uint8_t word_buf[8];
    int word_pos = 8; /* 8 = need fresh word */

    while (got < expected) {
        ssize_t r = read(fd, buf, CHUNK);
        if (r == 0) break;
        if (r < 0) { perror("read"); break; }
        if (verify) {
            for (ssize_t i = 0; i < r; i++) {
                if (word_pos == 8) {
                    uint64_t v = xs_next();
                    memcpy(word_buf, &v, 8);
                    word_pos = 0;
                }
                if (buf[i] != word_buf[word_pos]) mismatches++;
                word_pos++;
            }
        }
        got += r;
    }
    (void)expect;

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

    fprintf(stderr, "sink: got=%lld expected=%lld mismatches=%lld in %.3fs => %.2f MiB/s\n",
            got, expected, mismatches, dt, got / dt / (1024.0 * 1024.0));

    close(fd);
    free(buf); free(expect);
    return (got == expected && mismatches == 0) ? 0 : 1;
}
