# Protocol v1 golden fixtures

These UTF-8 JSON/NDJSON files are language-neutral compatibility fixtures.
Zig tests consume them with `@embedFile`; Rust clients can consume the same
files directly. Unknown fields and the unknown event are intentional and must
be ignored by v1 readers.
