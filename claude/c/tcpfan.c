/* tcpfan — single-source, multi-sink, byte-exact TCP relay.
 *
 * One source listener accepts one TCP connection at a time; bytes from that
 * source are fanned out unchanged to every connected sink. Each sink owns a
 * fixed-size ring buffer; sinks that overflow are dropped. Reverse traffic
 * from sinks is read and discarded. Single-threaded poll() event loop.
 *
 * See spec/SPEC.md and RULES.md.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

/* ---------- logging ---------- */
enum { LOG_QUIET = 0, LOG_NORMAL = 1, LOG_VERBOSE = 2 };
static int g_log_level = LOG_NORMAL;

static void logf(int level, const char *fmt, ...) {
    if (level > g_log_level) return;
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(stderr, "[%lld.%03ld] ", (long long)ts.tv_sec, ts.tv_nsec / 1000000);
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* ---------- config ---------- */
struct config {
    int source_port;
    int sink_port;
    int max_sinks;
    size_t read_min;
    size_t read_default;
    size_t read_max;
    size_t sink_buf;       /* per-sink pending bytes cap (rounded up to pow2) */
    int stats_interval_ms;
    int poll_timeout_ms;
};

#ifdef MSG_NOSIGNAL
#  define SEND_FLAGS MSG_NOSIGNAL
#else
#  define SEND_FLAGS 0
#endif

/* ---------- per-sink ring buffer ---------- */
struct sink {
    int fd;                /* -1 if slot is free */
    uint8_t *ring;         /* cap bytes */
    size_t cap;            /* power of two */
    size_t mask;           /* cap - 1 */
    size_t head;           /* read position (bytes) */
    size_t tail;           /* write position (bytes) */
    /* invariant: tail - head <= cap; pending = tail - head */
    uint64_t bytes_out;
    uint64_t bytes_discarded;   /* reverse traffic */
};

static inline size_t ring_pending(const struct sink *s) { return s->tail - s->head; }
static inline size_t ring_free(const struct sink *s)    { return s->cap - ring_pending(s); }

/* ---------- globals (single-threaded; volatile only for signal handlers) ---------- */
static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static struct config g_cfg;
static struct sink *g_sinks;          /* g_cfg.max_sinks slots */
static int *g_active;                 /* slot indices of active sinks */
static int g_n_sinks;                 /* count of in-use slots == active list length */
static int g_source_listen = -1;
static int g_sink_listen = -1;
static int g_source = -1;             /* current source fd or -1 */
static bool g_source_eof = false;

static uint8_t *g_readbuf;            /* read_max bytes */
static size_t g_read_size;            /* current adaptive read size */

static uint64_t g_total_in;
static uint64_t g_total_out;
static uint64_t g_total_reverse;
static uint64_t g_drops_overflow;     /* spec 9.3: drops by reason */
static uint64_t g_drops_error;
static uint64_t g_drops_peer;
static uint64_t g_sinks_accepted;
static uint64_t g_sources_seen;

/* ---------- helpers ---------- */
static int set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* role: 0 = source listener, 1 = sink listener. Buffer sizes are set on the
 * listener so accepted children inherit them (Darwin clamps post-accept
 * SO_*BUF requests differently than pre-listen ones; pre-listen wins). */
static int make_listener(int port, int role) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (role == 0) {
        size_t rcv_sz = g_cfg.read_max * 4;
        if (rcv_sz < (1u << 22)) rcv_sz = 1u << 22;
        if (rcv_sz > (1u << 24)) rcv_sz = 1u << 24;
        int rcv = (int)rcv_sz;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);
    } else {
        int snd = (int)g_cfg.sink_buf;
        if (snd > (1 << 22)) snd = 1 << 22;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, sizeof snd);
        int rcv = 4096;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);
    }
    set_nonblock(fd);
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons(port);
    if (bind(fd, (struct sockaddr*)&sa, sizeof sa) < 0) {
        fprintf(stderr, "bind port %d: %s\n", port, strerror(errno));
        close(fd); return -1;
    }
    if (listen(fd, 64) < 0) { perror("listen"); close(fd); return -1; }
    return fd;
}

/* Set per-conn options. NODELAY only on source (FIN-flush guarantee).
 * Buffer sizes inherited from listener; we just opt-in to NOSIGPIPE. */
static void set_conn_opts(int fd, bool is_source) {
    int one = 1;
    if (is_source) setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}

/* ---------- per-sink ops ---------- */
/* Close sink at slot `idx` and swap-remove from g_active. `ai` is the
 * index of `idx` in g_active (caller must know it; the fanout/service loops
 * iterate g_active so they have it for free). Pass -1 to look it up. */
static void close_sink_slot(int idx, int ai, const char *why) {
    struct sink *s = &g_sinks[idx];
    if (s->fd < 0) return;
    logf(LOG_NORMAL, "sink fd=%d closed (%s) bytes_out=%llu",
         s->fd, why, (unsigned long long)s->bytes_out);
    close(s->fd);
    s->fd = -1;
    s->head = s->tail = 0;
    if (ai < 0) {
        for (int k = 0; k < g_n_sinks; k++) if (g_active[k] == idx) { ai = k; break; }
    }
    if (ai >= 0) {
        g_n_sinks--;
        g_active[ai] = g_active[g_n_sinks];
    }
}

/* Push raw bytes into a sink's ring. Returns false if it doesn't fit. */
static bool ring_push(struct sink *s, const uint8_t *buf, size_t len) {
    if (len > ring_free(s)) return false;
    size_t pos = s->tail & s->mask;
    size_t first = s->cap - pos;
    if (first > len) first = len;
    memcpy(s->ring + pos, buf, first);
    if (len > first) memcpy(s->ring, buf + first, len - first);
    s->tail += len;
    return true;
}

/* Try to drain the sink ring to the socket. Returns 0 on success (may still
 * have pending), -1 if the sink should be closed due to error. */
static int sink_flush(struct sink *s) {
    while (ring_pending(s) > 0) {
        size_t pos = s->head & s->mask;
        size_t first = s->cap - pos;
        size_t pending = ring_pending(s);
        if (first > pending) first = pending;
        ssize_t w;
        if (first == pending) {
            /* contiguous — single send is cheaper than sendmsg */
            w = send(s->fd, s->ring + pos, first, SEND_FLAGS);
        } else {
            struct iovec iov[2] = {
                { .iov_base = s->ring + pos, .iov_len = first },
                { .iov_base = s->ring, .iov_len = pending - first },
            };
            struct msghdr mh = {0};
            mh.msg_iov = iov; mh.msg_iovlen = 2;
            w = sendmsg(s->fd, &mh, SEND_FLAGS);
        }
        if (w < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) return -1;
        s->head += (size_t)w;
        s->bytes_out += (uint64_t)w;
        g_total_out += (uint64_t)w;
        if ((size_t)w < pending) return 0; /* socket full */
    }
    return 0;
}

/* Fan-out a freshly-read chunk to all active sinks.
 *
 * Fast path: when the sink's ring is empty, send `buf` directly with no
 * memcpy; if the kernel accepts it all, done. If kernel returns EAGAIN
 * (buffer was empty but socket is full), enqueue and let POLLOUT drain —
 * issuing a second send to a kernel that just said EAGAIN is a wasted
 * syscall. Only on a *partial* send (or when ring already had data) do we
 * re-flush immediately, since the kernel may have just freed up space.
 *
 * Sets g_max_pending (per-call high-water of any sink's ring after fanout)
 * and returns true if any sink hit overflow/error (caller uses both to
 * gate adapt_read_size without re-walking counters).
 */
static size_t g_max_pending;
static bool fanout(const uint8_t *buf, size_t len) {
    bool any_drop = false;
    size_t max_pending = 0;
    /* Iterate the active list, not max_sinks. Walk in reverse so swap-remove
     * on close doesn't skip the swapped-in sink. */
    for (int ai = g_n_sinks - 1; ai >= 0; ai--) {
        int i = g_active[ai];
        struct sink *s = &g_sinks[i];
        size_t off = 0;
        bool tried_send = false;
        if (ring_pending(s) == 0) {
            tried_send = true;
            ssize_t w = send(s->fd, buf, len, SEND_FLAGS);
            if (w > 0) { off = (size_t)w; s->bytes_out += (uint64_t)w; g_total_out += (uint64_t)w; }
            else if (w == 0) { close_sink_slot(i, ai, "peer closed"); g_drops_peer++; any_drop = true; continue; }
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                close_sink_slot(i, ai, "send error"); g_drops_error++; any_drop = true; continue;
            }
        }
        if (off < len) {
            if (!ring_push(s, buf + off, len - off)) {
                close_sink_slot(i, ai, "buffer overflow"); g_drops_overflow++; any_drop = true; continue;
            }
            /* Skip immediate flush only on the empty-ring EAGAIN case
             * (tried_send && off == 0): the kernel just said no, a second
             * send is wasted. Otherwise (partial send, or ring had data)
             * try to drain now while the kernel may have freed space. */
            if (!(tried_send && off == 0) && sink_flush(s) < 0) {
                close_sink_slot(i, ai, "write error"); g_drops_error++; any_drop = true; continue;
            }
            size_t p = ring_pending(s);
            if (p > max_pending) max_pending = p;
        }
    }
    g_max_pending = max_pending;
    return any_drop;
}

/* ---------- accept handlers ---------- */
static void accept_source(void) {
    for (;;) {
        int fd = accept(g_source_listen, NULL, NULL);
        if (fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            perror("accept source"); return;
        }
        if (g_source >= 0) {
            logf(LOG_NORMAL, "rejecting extra source fd=%d", fd);
            close(fd);
            continue;
        }
        set_nonblock(fd);
        set_conn_opts(fd, true);
        g_source = fd;
        g_source_eof = false;
        g_read_size = g_cfg.read_default;
        g_sources_seen++;
        logf(LOG_NORMAL, "source connected fd=%d", fd);
    }
}

static void accept_sink(void) {
    for (;;) {
        int fd = accept(g_sink_listen, NULL, NULL);
        if (fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            perror("accept sink"); return;
        }
        if (g_n_sinks >= g_cfg.max_sinks) {
            logf(LOG_NORMAL, "sink limit (%d) reached, rejecting fd=%d",
                 g_cfg.max_sinks, fd);
            close(fd);
            continue;
        }
        int slot = -1;
        for (int i = 0; i < g_cfg.max_sinks; i++) {
            if (g_sinks[i].fd < 0) { slot = i; break; }
        }
        if (slot < 0) { close(fd); continue; }
        set_nonblock(fd);
        set_conn_opts(fd, false);
        struct sink *s = &g_sinks[slot];
        s->fd = fd;
        s->head = s->tail = 0;
        s->bytes_out = 0;
        s->bytes_discarded = 0;
        g_active[g_n_sinks++] = slot;
        g_sinks_accepted++;
        logf(LOG_NORMAL, "sink connected fd=%d slot=%d (now %d)", fd, slot, g_n_sinks);
    }
}

/* ---------- adaptive read sizing ---------- */
/* Strict equality on last_read==cur (Zig style): only grow when the kernel
 * actually filled our buffer. Shrink only on drops or *significant* backlog
 * (any sink past half its ring) — transient backlog from a partial-write
 * that drains on the next poll round-trip is normal at line rate and
 * shouldn't trigger oscillation. */
static void adapt_read_size(size_t last_read, bool heavy_backlog, bool any_drop) {
    size_t old = g_read_size;
    if (any_drop || heavy_backlog) {
        if (g_read_size > g_cfg.read_min) {
            g_read_size >>= 1;
            if (g_read_size < g_cfg.read_min) g_read_size = g_cfg.read_min;
        }
    } else if (last_read == old && g_read_size < g_cfg.read_max) {
        g_read_size <<= 1;
        if (g_read_size > g_cfg.read_max) g_read_size = g_cfg.read_max;
    }
    if (g_log_level >= LOG_VERBOSE && g_read_size != old) {
        logf(LOG_VERBOSE, "read_size %zu -> %zu (last=%zu heavy=%d drop=%d)",
             old, g_read_size, last_read, heavy_backlog, any_drop);
    }
}

/* ---------- session lifecycle ---------- */
static void end_session(const char *why) {
    if (g_source >= 0) {
        logf(LOG_NORMAL, "source disconnected (%s) total_in=%llu total_out=%llu",
             why,
             (unsigned long long)g_total_in,
             (unsigned long long)g_total_out);
        close(g_source);
        g_source = -1;
    }
    g_source_eof = false;
    /* Default: close all sinks at end of session. Walk active list in reverse
     * so swap-remove is safe. */
    for (int ai = g_n_sinks - 1; ai >= 0; ai--) {
        close_sink_slot(g_active[ai], ai, "session end");
    }
}

/* ---------- usage ---------- */
static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s --source-port N --sink-port N [options]\n"
        "  --max-sinks N           (default 64)\n"
        "  --read-min N            (default 4096)\n"
        "  --read-default N        (default 65536)\n"
        "  --read-max N            (default 1048576)\n"
        "  --sink-buf N            (default 8 MiB; rounded up to pow2)\n"
        "  --stats-interval-ms N   (default 1000, 0 = off)\n"
        "  --log-level L           (quiet|normal|verbose)\n",
        p);
}

static long parse_long(const char *s, const char *name) {
    char *end; errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || *end || v < 0) {
        fprintf(stderr, "bad value for %s: %s\n", name, s);
        exit(2);
    }
    return v;
}

int main(int argc, char **argv) {
    g_cfg.source_port = -1;
    g_cfg.sink_port = -1;
    g_cfg.max_sinks = 64;
    g_cfg.read_min = 4096;
    g_cfg.read_default = 65536;
    g_cfg.read_max = 1048576;
    g_cfg.sink_buf = 8 * 1024 * 1024;
    g_cfg.stats_interval_ms = 1000;
    g_cfg.poll_timeout_ms = 1000;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (i + 1 >= argc) { usage(argv[0]); return 2; }
        const char *v = argv[++i];
        if      (!strcmp(a, "--source-port"))       g_cfg.source_port = (int)parse_long(v, a);
        else if (!strcmp(a, "--sink-port"))         g_cfg.sink_port   = (int)parse_long(v, a);
        else if (!strcmp(a, "--max-sinks"))         g_cfg.max_sinks   = (int)parse_long(v, a);
        else if (!strcmp(a, "--read-min"))          g_cfg.read_min    = (size_t)parse_long(v, a);
        else if (!strcmp(a, "--read-default"))      g_cfg.read_default= (size_t)parse_long(v, a);
        else if (!strcmp(a, "--read-max"))          g_cfg.read_max    = (size_t)parse_long(v, a);
        else if (!strcmp(a, "--sink-buf"))          g_cfg.sink_buf    = (size_t)parse_long(v, a);
        else if (!strcmp(a, "--stats-interval-ms")) g_cfg.stats_interval_ms = (int)parse_long(v, a);
        else if (!strcmp(a, "--log-level")) {
            if      (!strcmp(v, "quiet"))   g_log_level = LOG_QUIET;
            else if (!strcmp(v, "normal"))  g_log_level = LOG_NORMAL;
            else if (!strcmp(v, "verbose")) g_log_level = LOG_VERBOSE;
            else { fprintf(stderr, "bad --log-level: %s\n", v); return 2; }
        } else { usage(argv[0]); return 2; }
    }
    if (g_cfg.source_port < 0 || g_cfg.sink_port < 0) { usage(argv[0]); return 2; }
    if (g_cfg.read_min < 1 || g_cfg.read_default < g_cfg.read_min ||
        g_cfg.read_max < g_cfg.read_default) {
        fprintf(stderr, "read-min <= read-default <= read-max required\n");
        return 2;
    }
    if (g_cfg.max_sinks < 1) { fprintf(stderr, "--max-sinks must be >= 1\n"); return 2; }

    /* Round sink_buf up to next power of two (min 4096) — ring uses mask. */
    size_t cap = 4096;
    while (cap < g_cfg.sink_buf) cap <<= 1;

    /* Signals: unify on sigaction. */
    struct sigaction sa_ign = {0};
    sa_ign.sa_handler = SIG_IGN;
    sigemptyset(&sa_ign.sa_mask);
    sigaction(SIGPIPE, &sa_ign, NULL);

    struct sigaction sa = {0};
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    g_sinks  = calloc((size_t)g_cfg.max_sinks, sizeof *g_sinks);
    g_active = calloc((size_t)g_cfg.max_sinks, sizeof *g_active);
    if (!g_sinks || !g_active) { perror("calloc"); return 1; }
    for (int i = 0; i < g_cfg.max_sinks; i++) {
        g_sinks[i].fd = -1;
        g_sinks[i].cap = cap;
        g_sinks[i].mask = cap - 1;
        g_sinks[i].ring = malloc(cap);
        if (!g_sinks[i].ring) { perror("malloc ring"); return 1; }
    }

    g_readbuf = malloc(g_cfg.read_max);
    if (!g_readbuf) { perror("malloc readbuf"); return 1; }
    g_read_size = g_cfg.read_default;

    g_source_listen = make_listener(g_cfg.source_port, 0);
    g_sink_listen   = make_listener(g_cfg.sink_port, 1);
    if (g_source_listen < 0 || g_sink_listen < 0) return 1;

    logf(LOG_NORMAL,
        "tcpfan up: src=:%d sink=:%d max_sinks=%d read[min/def/max]=%zu/%zu/%zu sink_buf=%zu",
        g_cfg.source_port, g_cfg.sink_port, g_cfg.max_sinks,
        g_cfg.read_min, g_cfg.read_default, g_cfg.read_max, cap);

    /* Pollfd layout (packed, active-only):
     *   [0]=src listener, [1]=sink listener, [2]=source conn (fd=-1 if none),
     *   [3 .. 3+g_n_sinks)=active sinks in g_active[] order. The kernel only
     *   sees the live fds, and the service loop maps pfds[3+ai] → g_active[ai]. */
    size_t pfd_cap = (size_t)g_cfg.max_sinks + 3;
    struct pollfd *pfds = calloc(pfd_cap, sizeof *pfds);
    if (!pfds) { perror("calloc pfds"); return 1; }
    pfds[0].fd = g_source_listen; pfds[0].events = POLLIN;
    pfds[1].fd = g_sink_listen;   pfds[1].events = POLLIN;
    pfds[2].fd = -1;

    struct timespec last_stats; clock_gettime(CLOCK_MONOTONIC, &last_stats);

    while (!g_stop) {
        /* Refresh poll set. Listeners are static (set above). */
        pfds[0].revents = pfds[1].revents = 0;
        pfds[2].fd = (g_source >= 0 && !g_source_eof) ? g_source : -1;
        pfds[2].events = (g_source >= 0 && !g_source_eof) ? POLLIN : 0;
        pfds[2].revents = 0;
        for (int ai = 0; ai < g_n_sinks; ai++) {
            struct sink *s = &g_sinks[g_active[ai]];
            struct pollfd *p = &pfds[3 + ai];
            p->fd = s->fd;
            short ev = POLLIN; /* always watch for FIN/reverse traffic */
            if (ring_pending(s) > 0) ev |= POLLOUT;
            p->events = ev;
            p->revents = 0;
        }
        nfds_t nfds = (nfds_t)(3 + g_n_sinks);

        int timeout = g_cfg.poll_timeout_ms;
        if (g_cfg.stats_interval_ms > 0 && g_cfg.stats_interval_ms < timeout)
            timeout = g_cfg.stats_interval_ms;

        int pr = poll(pfds, nfds, timeout);
        if (pr < 0) {
            if (errno == EINTR) continue;
            perror("poll"); break;
        }

        if (pr > 0) {
            /* Listeners. */
            if (pfds[0].revents) accept_source();
            if (pfds[1].revents) accept_sink();

            /* Service sinks before source: drain any backlog and reverse
             * traffic so the post-fanout backlog check sees fresh state.
             * pfds[3+ai] corresponds to g_active[ai]. Iterate in reverse so
             * swap-remove on close doesn't skip the swapped-in sink (its
             * pollfd entry was already processed at its old position). */
            for (int ai = g_n_sinks - 1; ai >= 0; ai--) {
                int i = g_active[ai];
                short re = pfds[3 + ai].revents;
                if (!re) continue;
                struct sink *s = &g_sinks[i];
                if (re & POLLIN) {
                    /* read-and-discard reverse traffic */
                    static uint8_t scratch[4096];
                    bool peer_gone = false;
                    for (;;) {
                        ssize_t r = read(s->fd, scratch, sizeof scratch);
                        if (r > 0) { s->bytes_discarded += (uint64_t)r; g_total_reverse += (uint64_t)r; continue; }
                        if (r == 0) { peer_gone = true; break; }
                        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                        if (errno == EINTR) continue;
                        peer_gone = true; break;
                    }
                    if (peer_gone) {
                        close_sink_slot(i, ai, "peer closed");
                        g_drops_peer++;
                        continue;
                    }
                }
                if (re & POLLOUT) {
                    if (sink_flush(s) < 0) {
                        close_sink_slot(i, ai, "write error");
                        g_drops_error++;
                        continue;
                    }
                }
                if (re & (POLLERR | POLLHUP | POLLNVAL)) {
                    if (s->fd >= 0 && !(re & POLLIN)) {
                        close_sink_slot(i, ai, "poll err");
                        g_drops_error++;
                    }
                }
            }

            /* Source last so drains have already run. */
            if (g_source >= 0 && pfds[2].revents) {
                short re = pfds[2].revents;
                if (re & (POLLERR | POLLHUP | POLLNVAL | POLLIN)) {
                    ssize_t r = read(g_source, g_readbuf, g_read_size);
                    if (r > 0) {
                        g_total_in += (uint64_t)r;
                        bool any_drop = fanout(g_readbuf, (size_t)r);
                        /* Heavy backlog = any sink past half its ring. */
                        bool heavy_backlog = g_max_pending > (g_sinks[0].cap / 2);
                        adapt_read_size((size_t)r, heavy_backlog, any_drop);
                    } else if (r == 0) {
                        g_source_eof = true;
                        logf(LOG_NORMAL, "source EOF");
                    } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        logf(LOG_NORMAL, "source read error: %s", strerror(errno));
                        g_source_eof = true;
                    }
                }
            }
        }

        /* If source has reached EOF and all sinks are drained, end session. */
        if (g_source >= 0 && g_source_eof) {
            bool all_drained = true;
            for (int ai = 0; ai < g_n_sinks; ai++) {
                if (ring_pending(&g_sinks[g_active[ai]]) > 0) { all_drained = false; break; }
            }
            if (all_drained) end_session("EOF");
        }

        /* Periodic stats. Spec 9.3: include drops by reason. */
        if (g_cfg.stats_interval_ms > 0) {
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            long ms = (now.tv_sec - last_stats.tv_sec) * 1000 +
                      (now.tv_nsec - last_stats.tv_nsec) / 1000000;
            if (ms >= g_cfg.stats_interval_ms) {
                logf(LOG_NORMAL,
                    "stats: src=%s sinks=%d in=%llu out=%llu reverse=%llu "
                    "drops_overflow=%llu drops_error=%llu drops_peer=%llu "
                    "sinks_accepted=%llu sources_seen=%llu rdsz=%zu",
                    g_source >= 0 ? "up" : "idle",
                    g_n_sinks,
                    (unsigned long long)g_total_in,
                    (unsigned long long)g_total_out,
                    (unsigned long long)g_total_reverse,
                    (unsigned long long)g_drops_overflow,
                    (unsigned long long)g_drops_error,
                    (unsigned long long)g_drops_peer,
                    (unsigned long long)g_sinks_accepted,
                    (unsigned long long)g_sources_seen,
                    g_read_size);
                last_stats = now;
            }
        }
    }

    logf(LOG_NORMAL, "shutting down");
    if (g_source >= 0) end_session("shutdown");
    for (int i = 0; i < g_cfg.max_sinks; i++) {
        if (g_sinks[i].fd >= 0) close(g_sinks[i].fd);
        free(g_sinks[i].ring);
    }
    free(g_sinks);
    free(g_active);
    free(g_readbuf);
    free(pfds);
    if (g_source_listen >= 0) close(g_source_listen);
    if (g_sink_listen   >= 0) close(g_sink_listen);
    return 0;
}
