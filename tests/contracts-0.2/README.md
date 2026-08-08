# SayAll 0.2 contract fixtures

These UTF-8 JSON files are language-neutral compatibility fixtures consumed by
Zig, Swift, and Rust tests.

`worker-*` fixtures describe the private `sayall-process` protocol version 2,
which adds explicit Deepgram formatting flags. Request decoders are strict; result readers validate required fields
and ignore unknown additive object fields. Requests are intentionally omitted
because they contain credentials and platform-owned secure audio paths; their
typed schemas and bounds remain tested in Zig and Swift.
`worker-info`, both ready modes, and `worker-finish` contain no credentials and
freeze the compatibility and streaming control frames shared by future hosts.
Terminal worker results may include the authoritative additive `transport`
field (`rest` or `stream`); older hosts ignore it, while qualification tooling
uses it to distinguish a completed stream from automatic REST fallback.

`host-*` fixtures freeze the future unified native-host control protocol
version 2. Version 2 is intentionally distinct from the released private macOS
version-1 protocol because errors become structured `{code,message}` values.
Status never launches a host. Toggle may launch the exact installed host, but a
client must not retry after the mutation could have been accepted. Reload
validates configuration while idle and applies it to the next dictation.

Unknown object fields are additive. Worker status/warning/error values and host
states are closed unless the architecture ADR explicitly marks a field open;
adding a closed value requires a protocol version change. Host error `code` is
open and clients must ignore unknown codes after presenting `message`.
