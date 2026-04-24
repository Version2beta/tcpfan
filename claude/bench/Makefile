CFLAGS ?= -O3 -Wall -Wextra -std=c11
all: source_writer sink_reader latency_source latency_sink
source_writer: source_writer.c
	$(CC) $(CFLAGS) -o $@ $<
sink_reader: sink_reader.c
	$(CC) $(CFLAGS) -o $@ $<
latency_source: latency_source.c
	$(CC) $(CFLAGS) -o $@ $<
latency_sink: latency_sink.c
	$(CC) $(CFLAGS) -o $@ $<
clean:
	rm -f source_writer sink_reader latency_source latency_sink
.PHONY: all clean
