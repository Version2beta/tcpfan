#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
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
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#ifndef POLLRDHUP
#define POLLRDHUP 0
#endif

enum log_level {
    LOG_ERROR = 0,
    LOG_WARN = 1,
    LOG_INFO = 2,
    LOG_DEBUG = 3,
};

enum discard_mode {
    DISCARD_AUTO = 0,
    DISCARD_KERNEL = 1,
    DISCARD_READ = 2,
};

enum sink_drop_reason {
    SINK_DROP_NONE = 0,
    SINK_DROP_POLL = 1,
    SINK_DROP_REVERSE = 2,
    SINK_DROP_WRITE = 3,
    SINK_DROP_OVERFLOW = 4,
    SINK_DROP_SESSION_END = 5,
};

typedef struct {
    int fd;
    uint8_t *buf;
    size_t cap;
    size_t len;
    size_t off;
    bool read_drop;
} sink_t;

typedef struct {
    const char *source_bind;
    const char *sink_bind;
    const char *source_port;
    const char *sink_port;
    int backlog;
    size_t max_sinks;
    size_t sink_pending_bytes;
    size_t read_min;
    size_t read_default;
    size_t read_max;
    size_t read_step_up;
    size_t read_step_down;
    int stats_interval_ms;
    int poll_timeout_ms;
    bool close_sinks_on_source_close;
    enum discard_mode discard_mode;
    enum log_level log_level;
} config_t;

typedef struct {
    uint64_t source_accept;
    uint64_t source_reject;
    uint64_t source_disconnect;
    uint64_t sink_accept;
    uint64_t sink_drop_overflow;
    uint64_t sink_drop_error;
    uint64_t bytes_from_source;
    uint64_t bytes_to_sinks;
    uint64_t sink_ingress_bytes;
    uint64_t sink_ingress_reads;
    uint64_t sink_ingress_kernel_mode;
    uint64_t poll_loops;
} stats_t;

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int signo) {
    (void)signo;
    g_stop = 1;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void logf_msg(enum log_level cur, enum log_level need, const char *fmt, ...) {
    static const char *names[] = {"ERROR", "WARN", "INFO", "DEBUG"};
    if (need > cur) {
        return;
    }
    fprintf(stderr, "[%s] ", names[need]);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return -1;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return -1;
    }
    return 0;
}

static void set_socket_common(int fd) {
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
}

static int parse_u64(const char *s, uint64_t *out) {
    if (!s || !*s) {
        return -1;
    }
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno != 0 || !end || *end != '\0') {
        return -1;
    }
    *out = (uint64_t)v;
    return 0;
}

static int make_listener(const char *bind_addr, const char *port, int backlog) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    struct addrinfo *res = NULL;
    int gai = getaddrinfo(bind_addr, port, &hints, &res);
    if (gai != 0) {
        fprintf(stderr, "getaddrinfo(%s,%s): %s\n", bind_addr ? bind_addr : "*", port, gai_strerror(gai));
        return -1;
    }

    int listen_fd = -1;
    for (struct addrinfo *it = res; it; it = it->ai_next) {
        int fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd < 0) {
            continue;
        }
        set_socket_common(fd);
        if (bind(fd, it->ai_addr, it->ai_addrlen) != 0) {
            close(fd);
            continue;
        }
        if (listen(fd, backlog) != 0) {
            close(fd);
            continue;
        }
        if (set_nonblocking(fd) != 0) {
            close(fd);
            continue;
        }
        listen_fd = fd;
        break;
    }

    freeaddrinfo(res);
    return listen_fd;
}

static void close_fd(int *fd) {
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

static size_t sink_space(const sink_t *s) {
    return s->cap - s->len;
}

static size_t ring_tail_index(const sink_t *s) {
    return (s->off + s->len) % s->cap;
}

static size_t ring_contig_tail(const sink_t *s) {
    size_t tail = ring_tail_index(s);
    if (tail >= s->off) {
        return s->cap - tail;
    }
    return s->off - tail;
}

static size_t ring_contig_head(const sink_t *s) {
    if (s->len == 0) {
        return 0;
    }
    if (s->off + s->len <= s->cap) {
        return s->len;
    }
    return s->cap - s->off;
}

static void ring_append(sink_t *s, const uint8_t *src, size_t n) {
    size_t left = n;
    while (left > 0) {
        size_t chunk = ring_contig_tail(s);
        if (chunk > left) {
            chunk = left;
        }
        memcpy(s->buf + ring_tail_index(s), src + (n - left), chunk);
        s->len += chunk;
        left -= chunk;
    }
}

static void ring_consume(sink_t *s, size_t n) {
    if (n >= s->len) {
        s->len = 0;
        s->off = 0;
        return;
    }
    s->off = (s->off + n) % s->cap;
    s->len -= n;
}

static int sink_enable_kernel_discard(int fd) {
    if (shutdown(fd, SHUT_RD) == 0) {
        return 0;
    }
    return -1;
}

static int recv_drop(int fd, stats_t *st) {
    uint8_t buf[65536];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n > 0) {
            st->sink_ingress_bytes += (uint64_t)n;
            st->sink_ingress_reads++;
            continue;
        }
        if (n == 0) {
            return 1;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return 0;
        }
        return -1;
    }
}

static int flush_sink(sink_t *s, stats_t *st) {
    while (s->len > 0) {
        size_t chunk = ring_contig_head(s);
        ssize_t n = send(s->fd, s->buf + s->off, chunk, MSG_NOSIGNAL);
        if (n > 0) {
            st->bytes_to_sinks += (uint64_t)n;
            ring_consume(s, (size_t)n);
            continue;
        }
        if (n == 0) {
            return -1;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return 0;
        }
        return -1;
    }
    return 0;
}

static void close_sink(sink_t *s) {
    if (s->fd >= 0) {
        close(s->fd);
    }
    free(s->buf);
    s->fd = -1;
    s->buf = NULL;
    s->cap = 0;
    s->len = 0;
    s->off = 0;
    s->read_drop = false;
}

static void remove_sink(sink_t *sinks, size_t *count, size_t idx) {
    close_sink(&sinks[idx]);
    size_t last = *count - 1;
    if (idx != last) {
        sinks[idx] = sinks[last];
    }
    (*count)--;
}

static const char *sink_drop_reason_name(uint8_t reason) {
    switch (reason) {
    case SINK_DROP_POLL:
        return "poll";
    case SINK_DROP_REVERSE:
        return "reverse";
    case SINK_DROP_WRITE:
        return "write";
    case SINK_DROP_OVERFLOW:
        return "overflow";
    case SINK_DROP_SESSION_END:
        return "session-end";
    default:
        return "unknown";
    }
}

static int accept_all(int lfd, int *out_fds, int max_count) {
    int n = 0;
    while (n < max_count) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        out_fds[n++] = cfd;
    }
    return n;
}

static void print_help(const char *prog) {
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  --source-port PORT            Source listener port (required)\n"
            "  --sink-port PORT              Sink listener port (required)\n"
            "  --source-bind ADDR            Source bind address (default 0.0.0.0)\n"
            "  --sink-bind ADDR              Sink bind address (default 0.0.0.0)\n"
            "  --backlog N                   listen() backlog (default 256)\n"
            "  --max-sinks N                 Max concurrent sinks (default 4096)\n"
            "  --sink-pending-bytes N        Per-sink pending buffer bytes (default 1048576)\n"
            "  --read-min N                  Adaptive read minimum bytes (default 4096)\n"
            "  --read-default N              Adaptive read default bytes (default 65536)\n"
            "  --read-max N                  Adaptive read maximum bytes (default 262144)\n"
            "  --read-step-up N              Adaptive increase step bytes (default 4096)\n"
            "  --read-step-down N            Adaptive decrease step bytes (default 4096)\n"
            "  --stats-interval-ms N         Stats log interval ms (default 5000, 0 disables)\n"
            "  --poll-timeout-ms N           poll timeout ms (default 250)\n"
            "  --log-level L                 quiet|normal|verbose (default normal)\n"
            "  --discard-mode M              auto|kernel|read (default auto)\n"
            "  --keep-sinks-on-source-close  Keep sinks when source disconnects (default false)\n"
            "  --help                        Show this help\n",
            prog);
}

static int parse_log_level(const char *s, enum log_level *out) {
    if (strcmp(s, "quiet") == 0) {
        *out = LOG_ERROR;
        return 0;
    }
    if (strcmp(s, "normal") == 0) {
        *out = LOG_INFO;
        return 0;
    }
    if (strcmp(s, "verbose") == 0) {
        *out = LOG_DEBUG;
        return 0;
    }
    if (strcmp(s, "error") == 0) {
        *out = LOG_ERROR;
        return 0;
    }
    if (strcmp(s, "warn") == 0) {
        *out = LOG_WARN;
        return 0;
    }
    if (strcmp(s, "info") == 0) {
        *out = LOG_INFO;
        return 0;
    }
    if (strcmp(s, "debug") == 0) {
        *out = LOG_DEBUG;
        return 0;
    }
    return -1;
}

static int parse_discard_mode(const char *s, enum discard_mode *out) {
    if (strcmp(s, "auto") == 0) {
        *out = DISCARD_AUTO;
        return 0;
    }
    if (strcmp(s, "kernel") == 0) {
        *out = DISCARD_KERNEL;
        return 0;
    }
    if (strcmp(s, "read") == 0) {
        *out = DISCARD_READ;
        return 0;
    }
    return -1;
}

static int parse_args(int argc, char **argv, config_t *cfg) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--help") == 0) {
            print_help(argv[0]);
            return 1;
        }

        if (strcmp(a, "--keep-sinks-on-source-close") == 0) {
            cfg->close_sinks_on_source_close = false;
            continue;
        }

        if (i + 1 >= argc) {
            fprintf(stderr, "Missing value for %s\n", a);
            return -1;
        }

        const char *v = argv[++i];
        uint64_t num = 0;

        if (strcmp(a, "--source-port") == 0) {
            cfg->source_port = v;
        } else if (strcmp(a, "--sink-port") == 0) {
            cfg->sink_port = v;
        } else if (strcmp(a, "--source-bind") == 0) {
            cfg->source_bind = v;
        } else if (strcmp(a, "--sink-bind") == 0) {
            cfg->sink_bind = v;
        } else if (strcmp(a, "--backlog") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0 || num > 32768) {
                fprintf(stderr, "Invalid --backlog\n");
                return -1;
            }
            cfg->backlog = (int)num;
        } else if (strcmp(a, "--max-sinks") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0 || num > 1000000ULL) {
                fprintf(stderr, "Invalid --max-sinks\n");
                return -1;
            }
            cfg->max_sinks = (size_t)num;
        } else if (strcmp(a, "--sink-pending-bytes") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0) {
                fprintf(stderr, "Invalid --sink-pending-bytes\n");
                return -1;
            }
            cfg->sink_pending_bytes = (size_t)num;
        } else if (strcmp(a, "--read-min") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0) {
                fprintf(stderr, "Invalid --read-min\n");
                return -1;
            }
            cfg->read_min = (size_t)num;
        } else if (strcmp(a, "--read-default") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0) {
                fprintf(stderr, "Invalid --read-default\n");
                return -1;
            }
            cfg->read_default = (size_t)num;
        } else if (strcmp(a, "--read-max") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0) {
                fprintf(stderr, "Invalid --read-max\n");
                return -1;
            }
            cfg->read_max = (size_t)num;
        } else if (strcmp(a, "--read-step-up") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0) {
                fprintf(stderr, "Invalid --read-step-up\n");
                return -1;
            }
            cfg->read_step_up = (size_t)num;
        } else if (strcmp(a, "--read-step-down") == 0) {
            if (parse_u64(v, &num) != 0 || num == 0) {
                fprintf(stderr, "Invalid --read-step-down\n");
                return -1;
            }
            cfg->read_step_down = (size_t)num;
        } else if (strcmp(a, "--stats-interval-ms") == 0) {
            if (parse_u64(v, &num) != 0 || num > 3600000ULL) {
                fprintf(stderr, "Invalid --stats-interval-ms\n");
                return -1;
            }
            cfg->stats_interval_ms = (int)num;
        } else if (strcmp(a, "--poll-timeout-ms") == 0) {
            if (parse_u64(v, &num) != 0 || num > 60000ULL) {
                fprintf(stderr, "Invalid --poll-timeout-ms\n");
                return -1;
            }
            cfg->poll_timeout_ms = (int)num;
        } else if (strcmp(a, "--log-level") == 0) {
            if (parse_log_level(v, &cfg->log_level) != 0) {
                fprintf(stderr, "Invalid --log-level\n");
                return -1;
            }
        } else if (strcmp(a, "--discard-mode") == 0) {
            if (parse_discard_mode(v, &cfg->discard_mode) != 0) {
                fprintf(stderr, "Invalid --discard-mode\n");
                return -1;
            }
        } else {
            fprintf(stderr, "Unknown option: %s\n", a);
            return -1;
        }
    }

    if (!cfg->source_port || !cfg->sink_port) {
        fprintf(stderr, "--source-port and --sink-port are required\n");
        return -1;
    }

    if (!(cfg->read_min <= cfg->read_default && cfg->read_default <= cfg->read_max)) {
        fprintf(stderr, "Require read-min <= read-default <= read-max\n");
        return -1;
    }

    if (cfg->sink_pending_bytes < cfg->read_max) {
        fprintf(stderr, "sink-pending-bytes should be >= read-max for predictable behavior\n");
    }

    return 0;
}

static void stats_log(enum log_level lvl, const stats_t *st, size_t sink_count, int source_fd, size_t read_size) {
    logf_msg(lvl, LOG_INFO,
             "stats source=%s sinks=%zu read_size=%zu src_accept=%llu src_reject=%llu src_disc=%llu sink_accept=%llu sink_drop_overflow=%llu sink_drop_error=%llu in=%llu out=%llu sink_ingress_bytes=%llu sink_ingress_reads=%llu sink_kernel_mode=%llu loops=%llu",
             source_fd >= 0 ? "up" : "down",
             sink_count,
             read_size,
             (unsigned long long)st->source_accept,
             (unsigned long long)st->source_reject,
             (unsigned long long)st->source_disconnect,
             (unsigned long long)st->sink_accept,
             (unsigned long long)st->sink_drop_overflow,
             (unsigned long long)st->sink_drop_error,
             (unsigned long long)st->bytes_from_source,
             (unsigned long long)st->bytes_to_sinks,
             (unsigned long long)st->sink_ingress_bytes,
             (unsigned long long)st->sink_ingress_reads,
             (unsigned long long)st->sink_ingress_kernel_mode,
             (unsigned long long)st->poll_loops);
}

int main(int argc, char **argv) {
    config_t cfg = {
        .source_bind = "0.0.0.0",
        .sink_bind = "0.0.0.0",
        .source_port = NULL,
        .sink_port = NULL,
        .backlog = 256,
        .max_sinks = 4096,
        .sink_pending_bytes = 1024 * 1024,
        .read_min = 4096,
        .read_default = 65536,
        .read_max = 262144,
        .read_step_up = 4096,
        .read_step_down = 4096,
        .stats_interval_ms = 5000,
        .poll_timeout_ms = 250,
        .close_sinks_on_source_close = true,
        .discard_mode = DISCARD_AUTO,
        .log_level = LOG_INFO,
    };

    int pa = parse_args(argc, argv, &cfg);
    if (pa != 0) {
        return pa > 0 ? 0 : 2;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    int source_listener = make_listener(cfg.source_bind, cfg.source_port, cfg.backlog);
    if (source_listener < 0) {
        fprintf(stderr, "Failed to create source listener\n");
        return 1;
    }

    int sink_listener = make_listener(cfg.sink_bind, cfg.sink_port, cfg.backlog);
    if (sink_listener < 0) {
        fprintf(stderr, "Failed to create sink listener\n");
        close(source_listener);
        return 1;
    }

    sink_t *sinks = calloc(cfg.max_sinks, sizeof(*sinks));
    if (!sinks) {
        fprintf(stderr, "OOM allocating sinks\n");
        close(source_listener);
        close(sink_listener);
        return 1;
    }
    for (size_t i = 0; i < cfg.max_sinks; i++) {
        sinks[i].fd = -1;
    }

    struct pollfd *pfds = calloc(cfg.max_sinks + 3, sizeof(*pfds));
    int *ptype = calloc(cfg.max_sinks + 3, sizeof(*ptype));
    int *pindex = calloc(cfg.max_sinks + 3, sizeof(*pindex));
    uint8_t *sink_drop = calloc(cfg.max_sinks, sizeof(*sink_drop));
    if (!pfds || !ptype || !pindex || !sink_drop) {
        fprintf(stderr, "OOM allocating poll arrays\n");
        free(pfds);
        free(ptype);
        free(pindex);
        free(sink_drop);
        free(sinks);
        close(source_listener);
        close(sink_listener);
        return 1;
    }

    int source_fd = -1;
    bool draining_close = false;
    size_t sink_count = 0;
    stats_t st;
    memset(&st, 0, sizeof(st));
    size_t read_size = cfg.read_default;
    uint8_t *src_buf = malloc(cfg.read_max);
    if (!src_buf) {
        fprintf(stderr, "OOM allocating source buffer\n");
        free(pfds);
        free(ptype);
        free(pindex);
        free(sink_drop);
        free(sinks);
        close(source_listener);
        close(sink_listener);
        return 1;
    }

    uint64_t next_stats = now_ms() + (uint64_t)cfg.stats_interval_ms;

    logf_msg(cfg.log_level, LOG_INFO,
             "listening source=%s:%s sink=%s:%s",
             cfg.source_bind, cfg.source_port, cfg.sink_bind, cfg.sink_port);

    while (!g_stop) {
        int nfd = 0;
        pfds[nfd].fd = source_listener;
        pfds[nfd].events = POLLIN;
        ptype[nfd] = 1;
        pindex[nfd] = -1;
        nfd++;

        pfds[nfd].fd = sink_listener;
        pfds[nfd].events = POLLIN;
        ptype[nfd] = 2;
        pindex[nfd] = -1;
        nfd++;

        if (source_fd >= 0) {
            pfds[nfd].fd = source_fd;
            pfds[nfd].events = POLLIN | POLLRDHUP;
            ptype[nfd] = 3;
            pindex[nfd] = -1;
            nfd++;
        }

        for (size_t i = 0; i < sink_count; i++) {
            short ev = POLLRDHUP;
            if (sinks[i].len > 0) {
                ev |= POLLOUT;
            }
            if (sinks[i].read_drop) {
                ev |= POLLIN;
            }
            pfds[nfd].fd = sinks[i].fd;
            pfds[nfd].events = ev;
            ptype[nfd] = 4;
            pindex[nfd] = (int)i;
            nfd++;
        }

        int pr = poll(pfds, (nfds_t)nfd, cfg.poll_timeout_ms);
        st.poll_loops++;
        if (pr < 0) {
            if (errno == EINTR) {
                continue;
            }
            logf_msg(cfg.log_level, LOG_ERROR, "poll error: %s", strerror(errno));
            break;
        }

        bool source_ended = false;
        bool source_hup = false;
        bool source_pollin = false;
        memset(sink_drop, 0, sink_count);

        for (int i = 0; i < nfd; i++) {
            if (pfds[i].revents == 0) {
                continue;
            }

            if (ptype[i] == 1 && (pfds[i].revents & POLLIN)) {
                int accepts[64];
                int got = accept_all(source_listener, accepts, 64);
                for (int j = 0; j < got; j++) {
                    int cfd = accepts[j];
                    set_socket_common(cfd);
                    if (set_nonblocking(cfd) != 0) {
                        close(cfd);
                        continue;
                    }
                    if (source_fd >= 0 || draining_close) {
                        st.source_reject++;
                        close(cfd);
                        continue;
                    }
                    source_fd = cfd;
                    st.source_accept++;
                    read_size = cfg.read_default;
                    logf_msg(cfg.log_level, LOG_INFO, "source connected");
                }
            } else if (ptype[i] == 2 && (pfds[i].revents & POLLIN)) {
                int accepts[128];
                int got = accept_all(sink_listener, accepts, 128);
                for (int j = 0; j < got; j++) {
                    int cfd = accepts[j];
                    set_socket_common(cfd);
                    if (set_nonblocking(cfd) != 0) {
                        close(cfd);
                        continue;
                    }
                    if (sink_count >= cfg.max_sinks) {
                        close(cfd);
                        st.sink_drop_error++;
                        logf_msg(cfg.log_level, LOG_WARN, "sink rejected: max-sinks reached");
                        continue;
                    }
                    if (draining_close) {
                        close(cfd);
                        st.sink_drop_error++;
                        logf_msg(cfg.log_level, LOG_WARN, "sink rejected: session closing");
                        continue;
                    }

                    sink_t s;
                    memset(&s, 0, sizeof(s));
                    s.fd = cfd;
                    s.cap = cfg.sink_pending_bytes;
                    s.buf = malloc(s.cap);
                    if (!s.buf) {
                        close(cfd);
                        st.sink_drop_error++;
                        continue;
                    }

                    bool do_read_drop = true;
                    if (cfg.discard_mode != DISCARD_READ) {
                        if (sink_enable_kernel_discard(cfd) == 0) {
                            do_read_drop = false;
                            st.sink_ingress_kernel_mode++;
                        } else if (cfg.discard_mode == DISCARD_KERNEL) {
                            logf_msg(cfg.log_level, LOG_WARN,
                                     "sink rejected: kernel discard unavailable");
                            close(cfd);
                            free(s.buf);
                            st.sink_drop_error++;
                            continue;
                        } else {
                            logf_msg(cfg.log_level, LOG_DEBUG,
                                     "kernel discard unavailable; falling back to read-drop");
                        }
                    }
                    s.read_drop = do_read_drop;

                    sinks[sink_count++] = s;
                    st.sink_accept++;
                    logf_msg(cfg.log_level, LOG_INFO,
                             "sink connected fd=%d discard=%s sinks=%zu",
                             cfd,
                             do_read_drop ? "read-drop" : "kernel",
                             sink_count);
                }
            } else if (ptype[i] == 3) {
                if (pfds[i].revents & (POLLERR | POLLHUP | POLLRDHUP | POLLNVAL)) {
                    source_hup = true;
                }
                if (pfds[i].revents & POLLIN) {
                    source_pollin = true;
                }
            }
        }

        for (size_t si = 0; si < sink_count; si++) {
            sink_t *s = &sinks[si];
            int got = 0;
            for (int i = 0; i < nfd; i++) {
                if (ptype[i] == 4 && pindex[i] == (int)si) {
                    got = pfds[i].revents;
                    break;
                }
            }

            bool drop = false;
            uint8_t drop_reason = SINK_DROP_NONE;
            if (got & (POLLERR | POLLHUP | POLLRDHUP | POLLNVAL)) {
                drop = true;
                drop_reason = SINK_DROP_POLL;
            }

            if (!drop && s->read_drop && (got & POLLIN)) {
                int rr = recv_drop(s->fd, &st);
                if (rr > 0 || rr < 0) {
                    drop = true;
                    drop_reason = SINK_DROP_REVERSE;
                }
            }

            if (!drop && s->len > 0 && ((got & POLLOUT) || pr == 0)) {
                if (flush_sink(s, &st) != 0) {
                    drop = true;
                    drop_reason = SINK_DROP_WRITE;
                }
            }

            if (drop) {
                st.sink_drop_error++;
                sink_drop[si] = drop_reason;
            }
        }

        size_t wr = 0;
        for (size_t rd = 0; rd < sink_count; rd++) {
            if (sink_drop[rd] != SINK_DROP_NONE) {
                logf_msg(cfg.log_level, LOG_INFO,
                         "sink dropped fd=%d reason=%s pending=%zu",
                         sinks[rd].fd,
                         sink_drop_reason_name(sink_drop[rd]),
                         sinks[rd].len);
                close_sink(&sinks[rd]);
                continue;
            }
            if (wr != rd) {
                sinks[wr] = sinks[rd];
            }
            wr++;
        }
        sink_count = wr;

        if (!source_ended && source_fd >= 0 && (source_pollin || source_hup)) {
            int read_burst = source_hup ? 1024 : 16;
            for (int k = 0; k < read_burst; k++) {
                size_t read_req = read_size;
                if (sink_count > 0) {
                    size_t min_space = (size_t)-1;
                    for (size_t si = 0; si < sink_count; si++) {
                        size_t space = sink_space(&sinks[si]);
                        if (space < min_space) {
                            min_space = space;
                        }
                    }
                    if (min_space == 0) {
                        break;
                    }
                    if (read_req > min_space) {
                        read_req = min_space;
                    }
                }

                ssize_t n = recv(source_fd, src_buf, read_req, 0);
                if (n > 0) {
                    st.bytes_from_source += (uint64_t)n;

                    size_t want = (size_t)n;
                    size_t prev_read_size = read_size;
                    if (read_req == read_size && want == read_req && read_size < cfg.read_max) {
                        size_t delta = cfg.read_step_up;
                        if (delta > cfg.read_max - read_size) {
                            delta = cfg.read_max - read_size;
                        }
                        read_size += delta;
                    } else if (want * 2 < read_req && read_size > cfg.read_min) {
                        size_t delta = cfg.read_step_down;
                        if (delta > read_size - cfg.read_min) {
                            delta = read_size - cfg.read_min;
                        }
                        read_size -= delta;
                    }
                    if (read_size != prev_read_size) {
                        logf_msg(cfg.log_level, LOG_DEBUG,
                                 "read-size changed %zu -> %zu", prev_read_size, read_size);
                    }

                    for (size_t si = 0; si < sink_count;) {
                        sink_t *s = &sinks[si];
                        if (sink_space(s) < want) {
                            st.sink_drop_overflow++;
                            logf_msg(cfg.log_level, LOG_WARN,
                                     "sink dropped fd=%d reason=%s pending=%zu cap=%zu",
                                     s->fd,
                                     sink_drop_reason_name(SINK_DROP_OVERFLOW),
                                     s->len,
                                     s->cap);
                            remove_sink(sinks, &sink_count, si);
                            continue;
                        }
                        ring_append(s, src_buf, want);
                        si++;
                    }
                    continue;
                }

                if (n == 0) {
                    source_ended = true;
                    break;
                }
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    if (source_hup) {
                        source_ended = true;
                    }
                    break;
                }
                if (errno == EINTR) {
                    continue;
                }
                source_ended = true;
                break;
            }
        }
        if (!source_ended && source_fd >= 0 && source_hup && !source_pollin) {
            source_ended = true;
        }

        if (source_ended && source_fd >= 0) {
            st.source_disconnect++;
            close_fd(&source_fd);
            logf_msg(cfg.log_level, LOG_INFO, "source disconnected");
            if (cfg.close_sinks_on_source_close) {
                draining_close = true;
            }
        }

        if (draining_close) {
            bool all_empty = true;
            for (size_t i = 0; i < sink_count; i++) {
                if (sinks[i].len > 0) {
                    all_empty = false;
                    break;
                }
            }
            if (all_empty) {
                while (sink_count > 0) {
                    sink_t *s = &sinks[sink_count - 1];
                    logf_msg(cfg.log_level, LOG_INFO,
                             "sink closed fd=%d reason=%s pending=%zu",
                             s->fd,
                             sink_drop_reason_name(SINK_DROP_SESSION_END),
                             s->len);
                    remove_sink(sinks, &sink_count, sink_count - 1);
                }
                draining_close = false;
                logf_msg(cfg.log_level, LOG_INFO, "all sinks closed at session end");
            }
        }

        if (cfg.stats_interval_ms > 0) {
            uint64_t now = now_ms();
            if (now >= next_stats) {
                stats_log(cfg.log_level, &st, sink_count, source_fd, read_size);
                next_stats = now + (uint64_t)cfg.stats_interval_ms;
            }
        }
    }

    logf_msg(cfg.log_level, LOG_INFO, "shutting down");
    close_fd(&source_fd);
    while (sink_count > 0) {
        remove_sink(sinks, &sink_count, sink_count - 1);
    }
    close(source_listener);
    close(sink_listener);
    stats_log(cfg.log_level, &st, 0, -1, read_size);

    free(src_buf);
    free(pfds);
    free(ptype);
    free(pindex);
    free(sink_drop);
    free(sinks);
    return 0;
}
