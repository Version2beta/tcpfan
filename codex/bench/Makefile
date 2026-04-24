CFLAGS ?= -O3 -Wall -Wextra -std=c11
all: source_writer sink_reader
source_writer: source_writer.c
	$(CC) $(CFLAGS) -o $@ $<
sink_reader: sink_reader.c
	$(CC) $(CFLAGS) -o $@ $<
clean:
	rm -f source_writer sink_reader
.PHONY: all clean
