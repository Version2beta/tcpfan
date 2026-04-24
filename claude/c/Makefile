CFLAGS ?= -O3 -Wall -Wextra -Wpedantic -std=c11 \
          -ffunction-sections -fdata-sections \
          -fno-unwind-tables -fno-asynchronous-unwind-tables

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LDFLAGS ?= -Wl,-dead_strip
else
  LDFLAGS ?= -Wl,--gc-sections
endif

all: tcpfan

tcpfan: tcpfan.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	strip $@ 2>/dev/null || true

clean:
	rm -f tcpfan

.PHONY: all clean
