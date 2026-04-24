# Transparent One-to-Many TCP Relay — Tight Specification  
  
## 1. Purpose  
  
Implement a compact, portable C program that relays a single inbound TCP byte stream to multiple outbound TCP sink connections without inspecting or modifying the stream.  
  
The program operates strictly at the TCP byte-stream level. It is not a proxy, parser, replay system, or multiplexing layer.  
  
---  
  
## 2. Core Behavioral Model  
  
A **relay session** consists of:  
  
- One active **source** TCP connection  
- Zero or more active **sink** TCP connections  
- Byte-for-byte forwarding from source to all sinks  
- No meaningful reverse path from sinks to source  
  
A session begins when a source connection is accepted and ends when that source disconnects or fails.  
  
By default, all sinks are scoped to the session and are closed when the source disconnects.  
  
---  
  
## 3. Non-Goals  
  
The program must not:  
  
- Parse or inspect payload data  
- Recognize or handle application protocols (HTTP, etc.)  
- Modify or frame the stream  
- Support bidirectional proxying  
- Replay data to late-joining sinks  
- Support multiple simultaneous source connections  
- Implement TLS  
- Provide persistent or guaranteed delivery  
- Prevent data loss across slow or failing sinks  
  
---  
  
## 4. Design Decisions (Intentional Constraints)  
  
### 4.1 Single Active Source  
Only one source connection is active at a time.  
  
- Ensures deterministic behavior  
- Avoids multiplexing complexity  
  
### 4.2 Multiple Sink Clients  
Multiple sinks may connect during a session.  
  
- Late sinks receive only new data  
- No replay or buffering for past data  
  
### 4.3 Reverse Traffic Ignored  
Data sent by sinks:  
  
- Is never forwarded  
- Is discarded (preferably by kernel)  
  
### 4.4 Slow Sink Handling  
Each sink has bounded output buffering.  
  
- Slow sinks are dropped if limits exceeded  
- Prevents system-wide slowdown  
  
### 4.5 Session-Scoped Sinks  
Default behavior:  
  
- All sinks close when source disconnects  
  
### 4.6 Single-Threaded Event Loop  
- Nonblocking I/O  
- No threading  
- Minimal synchronization complexity  
  
### 4.7 `poll()` as Baseline  
- Portable across Linux, FreeBSD, macOS  
- Simpler than epoll/kqueue variants  
  
### 4.8 Bounded Adaptive Behavior  
- Adaptive read sizing only  
- Strict min/max bounds  
- No complex control systems  
  
---  
  
## 5. External Behavior  
  
### 5.1 Listener Roles  
  
#### Source Listener  
- Accepts the single source connection  
- Rejects or closes additional source attempts  
  
#### Sink Listener  
- Accepts multiple sink connections  
- May enforce max sink limit  
  
---  
  
### 5.2 Forwarding Semantics  
  
For each read from source:  
  
- Bytes are forwarded unchanged to all sinks  
- Ordering is preserved  
- Partial writes are handled correctly  
  
---  
  
### 5.3 Reverse Traffic Handling  
  
For sink-originated data:  
  
- Discard immediately  
- Use OS-level discard when available  
- Otherwise read-and-drop in user space  
- Maintain discard counters  
  
---  
  
## 6. Backpressure and Delivery Policy  
  
- Lossless for active, healthy sinks within limits  
- Lossy across sink membership  
  
### Default Policy  
  
- Bounded per-sink buffers  
- Drop sink on overflow  
- Continue session  
  
---  
  
## 7. Resource and Memory Model  
  
### 7.1 Bounded Memory  
  
Memory is limited by:  
  
- Read buffer bounds  
- Number of sinks  
- Per-sink pending limits  
  
### 7.2 Named Defaults  
  
All constants must be:  
  
- Named  
- Documented  
- CLI-overridable  
  
---  
  
## 8. Adaptation  
  
### 8.1 Adaptive Read Size  
  
Adjust read size based on:  
  
Increase when:  
- Reads are full  
- Writes are fast  
- Low backlog  
  
Decrease when:  
- Backlog grows  
- Writes stall  
- Sinks drop  
  
### 8.2 Constraints  
  
Adaptive logic must:  
  
- Stay within bounds  
- Use simple step changes  
- Not affect correctness  
  
---  
  
## 9. Logging and Observability  
  
### 9.1 Required Events  
  
- Startup config  
- Source connect/disconnect  
- Sink connect/disconnect/drop  
- Bytes read/written  
- Reverse bytes discarded  
- Adaptation changes  
- Periodic stats  
  
### 9.2 Log Levels  
  
- Quiet  
- Normal  
- Verbose  
  
### 9.3 Periodic Stats  
  
Include:  
  
- Active session state  
- Sink count  
- Total bytes in/out  
- Drops by reason  
- Current read size  
  
---  
  
## 10. Portability  
  
### Requirements  
  
- Linux, FreeBSD, macOS (2026)  
- POSIX sockets  
- Minimal dependencies  
  
### Platform Features  
  
- Use conditional socket options  
- Graceful fallback if unsupported  
  
---  
  
## 11. Safety Requirements  
  
Must avoid:  
  
- Use-after-free  
- Double close  
- Buffer overflows  
- Blocking I/O  
- SIGPIPE termination  
- Descriptor misuse  
- Unbounded memory growth  
  
Must support clean shutdown.  
  
---  
  
# 12. State Machine  
  
## 12.1 Relay Session States  
  
### BOOT  
- Initialize system  
- Setup listeners  
  
→ IDLE  
  
---  
  
### IDLE  
- No active source  
  
Transitions:  
- Source accepted → SESSION_ACTIVE  
- Shutdown → TERMINATING  
  
---  
  
### SESSION_ACTIVE  
- Core relay loop  
  
Handles:  
- Source reads  
- Sink writes  
- Sink reads (discard)  
- New connections  
- Adaptation  
  
Transitions:  
- Source closes → SESSION_ENDING  
- Shutdown → TERMINATING  
  
---  
  
### SESSION_ENDING  
- Cleanup session  
  
Actions:  
- Close source  
- Close sinks (default)  
- Reset state  
  
→ IDLE  
  
---  
  
### TERMINATING  
- Shutdown system  
- Close all sockets  
- Exit  
  
---  
  
## 12.2 Sink State Machine  
  
### SINK_ACTIVE  
- Connected and receiving data  
  
Transitions:  
- Disconnect → SINK_CLOSED  
- Error → SINK_CLOSED  
- Overflow → SINK_DROPPED  
  
---  
  
### SINK_DROPPED  
- Removed due to policy  
  
→ Terminal  
  
---  
  
### SINK_CLOSED  
- Normal closure  
  
→ Terminal  
  
---  
  
## 13. Event Loop Rules  
  
### Source Readable  
- Read data  
- Forward to sinks  
- Handle EOF/errors  
  
---  
  
### Sink Writable  
- Flush pending data  
- Handle partial writes  
- Drop on overflow  
  
---  
  
### Sink Readable  
- Discard data  
- Use kernel discard if possible  
  
---  
  
### Listener Readable  
- Accept connections  
- Enforce limits  
  
---  
  
## 14. CLI Configuration  
  
Must support:  
  
- Source bind address/port  
- Sink bind address/port  
- Max sinks  
- Read size min/default/max  
- Per-sink buffer limit  
- Event loop timeout  
- Stats interval  
- Logging level  
- Sink/session behavior options  
  
---  
  
## 15. Acceptance Criteria  
  
1. One active source only  
2. Exact byte forwarding  
3. No reverse forwarding  
4. Efficient discard of sink data  
5. Slow sinks do not stall system  
6. Memory remains bounded  
7. Clean session lifecycle  
8. Sink lifecycle tied to session (default)  
9. All constants configurable  
10. Cross-platform support  
11. Nonblocking, single-threaded  
12. Observable via logs/stats  
  
---  
  
## 16. Summary  
  
A:  
  
- Single-session  
- One-way  
- One-to-many TCP relay  
  
With:  
  
- No inspection  
- No replay  
- Bounded memory  
- Sink-drop backpressure  
- Adaptive read sizing  
- Portable implementation  
  
---  
  
# 17. Open Questions for Client  
  
These need confirmation before implementation:  
  
### Behavior & Semantics  
  
1. Should sinks be allowed to connect before a source exists?  
   - If yes: should they block, receive nothing, or be rejected?  
  
2. On source disconnect:  
   - Confirm default: close all sinks  
   - Or allow sinks to persist for next session?  
  
3. Should multiple source connection attempts:  
   - Be rejected  
   - Or queued until current session ends?  
  
---  
  
### Backpressure Policy  
  
4. Confirm sink drop policy:  
   - Drop immediately on buffer overflow?  
   - Or allow temporary grace?  
  
5. Should there be:  
   - A max drop rate before terminating session?  
  
---  
  
### Adaptation  
  
6. Is adaptive read sizing sufficient, or should:  
   - Write pacing also adapt?  
  
7. Should adaptation be:  
   - Fully automatic  
   - Or optionally disabled?  
  
---  
  
### Reverse Traffic  
  
8. Confirm:  
   - No logging of payload content  
   - Only byte counts allowed?  
  
9. Should reverse traffic ever:  
   - Trigger sink removal (e.g., excessive inbound data)?  
  
---  
  
### Observability  
  
10. Required logging format:  
    - Plain text  
    - Structured (JSON)  
    - Both?  
  
11. Should metrics be:  
    - Logged only  
    - Exposed via socket or endpoint?  
  
---  
  
### Scaling  
  
12. Expected max sinks:  
    - Tens  
    - Hundreds  
    - Thousands?  
  
13. Is `poll()` sufficient for target scale, or should:  
    - epoll/kqueue be considered later?  
  
---  
  
### Platform Features  
  
14. Are we allowed to:  
    - Use platform-specific optimizations aggressively  
    - Or must portability dominate?  
  
---  
  
### Operational  
  
15. Should the program:  
    - Run as foreground CLI tool  
    - Support daemon mode?  
  
16. Should it support:  
    - Hot reload of configuration  
    - Or restart-only changes?  
  
---  
  
## Final Note  
  
This specification deliberately constrains scope to ensure:  
  
- correctness  
- bounded resource usage  
- portability  
- simplicity  
  
Any expansion (multi-source, replay, TLS, fairness scheduling) moves the system into a fundamentally different class of software.  
