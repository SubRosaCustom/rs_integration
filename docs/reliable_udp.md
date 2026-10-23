# Reliable UDP events: protocol 10

Control protocol 10 adds batched transport bodies, native-send cadence and replaceable latest-state events. It retains protocol 9 resource-pack policy snapshots; see [resource pack policy](resource_packs.md). Client and integration versions must match.

Client and server must upgrade together. Protocol 9 and older peers are rejected by the
existing exact-version handshake. Roll back both modules together. Core adds `emitServerEventLatest`; existing reliable API names and argument types are unchanged.

`HELLO_ACK.maxEventBytes` advertises the server's event limit (1024–262144).
The limit counts the complete encoded argument block, including its `SRCA`
header and argument tags/lengths, but excluding the 18-byte event envelope.
Ordinary events and processing results use the same reliable transport. Delivery is
unordered. Queue acceptance is not confirmation of delivery or processing.
Disconnect discards pending transfers; it does not replay them in a new session.

## Wire format

All integers are unsigned big-endian. The existing 44-byte outer envelope is:

`7DFP | SRCU | version:u8=2 | flags:u8=0 | token:32 bytes | bodyLength:u16`

The session token comes from the TCP handshake. Each datagram carries one body:

| Body | Fields after its one-byte type |
| --- | --- |
| Data (1) | kind:u8, messageID:u32, generation:u16, totalBytes:u32, chunkBytes:u16, index:u16, data |
| Receipt (2) | kind:u8, messageID:u32, generation:u16, fragmentCount:u16, complete:u8, bitmap |
| Size probe (3) | probeID:u32, zero padding to a 1156-byte body |
| Probe reply (4) | probeID:u32 |
| Frame batch (5) | count:u16, repeated (frameBytes:u16, frame:bytes) |
| Latest state (6) | complete kind-1 event envelope, 18..503 bytes |

A frame batch holds at least two length-delimited transport frames (types 1–4 or 6).
Nested batches, truncated frames, invalid counts and trailing bytes are rejected.
Batch framing is validated before processing contained frames. The shared buffer
budget is charged across the entire batch, rather than independently per frame.
A single frame uses its existing unwrapped representation, and the full-size
probe remains a standalone datagram. Batching changes no event/result identity,
completion receipt or application-result semantics.

Queued events do not send immediately. Each native game send opportunity flushes
up to eight SRC datagrams for that peer (at most 9,600 bytes of UDP payload),
packing eligible receipts, event/result fragments and probe replies up to the
per-packet size and congestion-window limits. An empty queue or a full reliable window with no eligible latest-state frames stops
the flush early. Extra frames remain queued for the next opportunity. The server
also stops after a failed native send attempt, leaving reliable retry policy in
charge of delivery. Client binding requests remain single-shot per callback.
There is no additional transport pacing timer, so consecutive native sends may both emit even at the same clock
value. When no frame is ready, no extra SRC datagram is emitted.

Before a successful size probe, batches stay within 548 bytes including the
outer header. Afterwards, they may use up to 1200 bytes. Full-size standalone
fragments retain their existing chunk sizes and fallback behavior.

Data wraps the existing encoded event/result envelope. `kind` is 1 (event) or
3 (result); the inner kind and message ID must match. `totalBytes` includes the
18-byte envelope and is at most 262162. Indexes start at zero. Fragment count is
`ceil(totalBytes/chunkBytes)`. All fragments except the last have exactly
`chunkBytes` bytes. Receipt bitmap bit `index % 8` in byte `index / 8` indicates
storage; unused bits are zero. A complete receipt has every fragment bit set.
The four-byte empty v1 batch remains only as the UDP endpoint-binding body,
inside the version-2 outer envelope.

## Size selection and retry

Start with 488-byte chunks: 44 envelope + 16 fragment header + 488 data =
548 bytes of UDP payload (576 bytes with ordinary IPv4/UDP headers).
A matching reply to a 1200-byte UDP probe enables 1024-byte chunks for new
transfers. Their datagrams are 1084 bytes. Every datagram remains at most 1200
bytes, including control traffic. No assumption of a 1500-byte path is required.

Large transfers restart with generation 2 and 488-byte chunks after three
unacknowledged transmissions of a fragment. An unsuccessful periodic size probe
also triggers this fallback. Existing small transfers keep their generation.
Old-generation receipts/fragments cannot alter a restarted assembly. Logical
message identity survives restart, so a previously completed event is not run
again. Successful probes affect only newly queued transfers.

This is delivery-size probing and black-hole recovery, **not proof of an
unfragmented path MTU**: the native game/Steam send path does not expose per-packet
DF control or validated ICMP size feedback here. The conservative fallback can
also fail on still-smaller paths. Such failures terminate the SRC session with
a diagnostic rather than claiming delivery.

Send attempts start retry timers. Bitmap receipts selectively suppress retries.
A final-fragment retry solicits a lost completion receipt. The receiver records
completion before handler dispatch; a result independently reports processing.
A lost result is retried even after the original event's receipt was delivered.

A per-peer window starts at two fragments, grows to eight with acknowledgements,
and halves on loss. Native game send opportunities determine transmission cadence;
RTT still informs retransmission deadlines. Transfers rotate in round-robin order.
Receipts precede data and may share a datagram with data. Retransmission
backoff is capped at four seconds. Default retry count is five per fragment;
server `eventRetryBaseTicks` and `eventRetryMaxAttempts` still tune this policy.
Whole-event retry queues no longer compete with fragment retries.

## Bounds and lifecycle

- At most 32 outbound and 32 incomplete inbound transfers per peer.
- At most 1 MiB of reserved message bytes across both directions per peer.
- The server additionally caps reserved message bytes across peers at 16 MiB.
- Transfer deadline: 120 seconds of active transport time, including queueing.
- Up to 32768 completed transfers retained for 240 active seconds. Exhausting this
  receive budget closes the session; completed records are not silently evicted.
- Retired ID watermarks reject packets older than the replay window. IDs are not
  reused within a session. Client exhaustion requires reconnect; exhaustion of
  the server-wide ID allocator requires restart.

Byte limits count logical buffers, not total allocator/table overhead. Envelope
validation happens before completion is accepted. Handler argument errors use
the existing processing-result path. Server binding is checked
before dispatch. Conflicting metadata, duplicate bytes, invalid dimensions,
quota exhaustion and expired assemblies terminate the affected SRC session.
This preserves uncertainty: disconnect after execution does not prove that a
handler never ran.

Sync refresh preserves transport state and pauses its timers. Disconnect and
new-token handshakes reset it. Server result deadlines allow the configured
processing timeout plus 120 seconds for result delivery.

## Validation

From `rs_integration`: `lua test/reliable_udp_test.lua` and
`lua test/udp_adapter_test.lua` (host tests use Lua 5.4).
Production modules also pass LuaJIT syntax loading; no Lua 5.3 bitwise syntax is
used by the transport.

Client CTest registers `reliable_udp_test` and `reliable_udp_codec_test`, plus
Lua, adapter and C++/Lua interoperability checks when the sibling server repo and
Lua executable are present. Checks cover boundary sizes, loss, reordering,
duplicates, lost completion receipts, path-size reduction, result delivery,
malformed fragments/batches, shared batch budgets, per-native-send cadence, bounded multi-packet flushes, carryover, native-buffer restoration, packet overflow, expiry, replay rejection and reset. Runtime checks
remain enabled in Release builds.

These host tests do not replace native Windows/Linux builds or live game tests
through direct UDP and Steam P2P. The existing RosaServer UDP probe test also
uses the new envelope and completion bitmap; run the full server harness on its
supported Linux environment before release.

### Latest-state events (protocol 10)

Body type 6 is one byte (`6`) followed by a complete kind-1 event envelope with flags zero. The envelope is 18..503 bytes, leaving at most 485 encoded argument bytes. The 44-byte outer envelope and 1200-byte datagram cap still apply. Type 6 can be included in a type-5 batch.

`emitServerEventLatest` and `src.emitClientEventLatest` opt into this lane. Each peer keeps at most one unsent message per event hash and 32 distinct latest-state hashes per session. New queued values replace old queued values. Receivers retain the highest message ID per hash and discard older or duplicate IDs. Normal event handlers receive the decoded values, but no transport receipt or processing result is generated, no reliable pending-event slot is occupied, and no retry is scheduled. A lost final update stays lost until the application sends another value. Authorization remains the handler's responsibility. Session reset clears these queues and sequence histories.

Protocol 10 requires matching client and server upgrades. The unreleased protocol 10 includes both batched frames and latest-state body type 6. Normal reliable events keep their existing guarantees.
