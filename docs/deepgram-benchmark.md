# Live Deepgram worker benchmark

This opt-in harness exercises the built `sayall-process` worker through both its
REST and streaming protocols. Its tiny generated corpus is a **connectivity and
regression canary**, not representative speech-recognition accuracy coverage.
It neither qualifies microphones, hardware, capture, the HUD, nor replaces the
physical release tests.

## Local run

Install Python 3, `espeak-ng`, and SoX, then build and run with a dedicated,
limited Deepgram test key:

```sh
zig build process -Doptimize=ReleaseSafe
export SAYALL_DEEPGRAM_BENCHMARK_API_KEY='...'
python3 tests/deepgram_benchmark/benchmark.py --mode both --output deepgram-benchmark.json
python3 -m unittest discover -s tests/deepgram_benchmark -p 'test_*.py'
```

The key is read only from the named environment variable and sent to the worker
inside its stdin request. The worker receives an empty environment; keys are
never argv, logs, or reports. Groq cleanup is disabled. Every operation is
bounded and temporary canonical mono 16 kHz signed-16 WAV/PCM is deleted. Use
`--dry-run` to validate the manifest and report schema without a key, worker,
synthesis tools, or network. A live report records the generated audio hash and
the report records a hash of each generation recipe, but it never includes a
provider transcript. WER/CER normalization ignores Unicode case, punctuation,
and spacing.
Thresholds are advisory unless `--enforce` is supplied; for example:

```sh
python3 tests/deepgram_benchmark/benchmark.py --enforce --max-wer .35 --max-cer .20
```

Enforcement always requires successful/nonempty speech, expected no-speech,
and a terminal worker result whose authoritative `transport` is `stream` for
stream-mode clips. The initial `streaming_active` ready flag only says that a
session started; a later WebSocket/finalization failure can still produce an
automatic REST result and is reported as such. Run the workflow several times
across normal provider variance before selecting thresholds. Record the model,
region, manifest hash and individual JSON artifacts used for a baseline.

## Adding real speech

Add small, consented recordings or clearly CC-licensed material to a new
versioned manifest. Each clip must identify its source path/recipe, expected
transcript, language, no-speech expectation, provenance, license, and SHA-256;
verify checked-in bytes against that hash in review. Do not replace manifest v1
or add recordings of uncertain origin. A future `source.type` can be added to
fixture loading without changing scoring or worker invocation.

For a frozen release candidate, manually dispatch the separate workflow at the
exact candidate commit, retain its JSON artifact, compare repeated runs with
the established baseline, and treat anomalies as investigation signals—not as
authorization to release. Physical supported-platform qualification remains
mandatory.
