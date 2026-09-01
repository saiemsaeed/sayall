# Live Deepgram worker benchmark

This harness exercises the built `sayall-process` worker through both its REST
and streaming protocols. Its frozen CC BY 4.0 LibriSpeech corpus measures clean
human read speech and provider drift. It is still a **provider canary**, not a
claim about every accent, microphone, room, noise condition, or spontaneous
dictation. It neither qualifies microphone hardware, native capture, the HUD,
nor replaces physical release tests.

## Local run

Install Python 3, then build and run with a dedicated, limited Deepgram test
key:

```sh
zig build process -Doptimize=ReleaseSafe
export SAYALL_DEEPGRAM_BENCHMARK_API_KEY='...'
python3 tests/deepgram_benchmark/benchmark.py --mode both --runs 5 --output deepgram-benchmark.json
python3 -m unittest discover -s tests/deepgram_benchmark -p 'test_*.py'

# Explicit extended qualification: eight utterances, seven speakers, clean,
# deterministic office noise at 10 dB and 5 dB, repeated twice.
python3 tests/deepgram_benchmark/benchmark.py --mode both --runs 2 \
  --manifest tests/deepgram_benchmark/manifest-v3.json \
  --output deepgram-qualification.json

# Representative workplace speech: 2,000+ words, two speakers, 20–40 seconds.
python3 tests/dictation_corpus/build_ami.py --output dist/ami-dictation-v1 --max-rows 6000
python3 tests/dictation_corpus/validate.py dist/ami-dictation-v1/manifest.json
python3 tests/deepgram_benchmark/benchmark.py --mode both --runs 1 \
  --manifest dist/ami-dictation-v1/manifest.json \
  --processing-profiles verbatim,clean --output deepgram-ami.json
```

The key is read only from the named environment variable and sent to the worker
inside its stdin request. The worker receives an empty environment; keys are
never argv, logs, or reports. Cerebras cleanup is disabled. Every operation is
bounded and temporary canonical mono 16 kHz signed-16 WAV/PCM is deleted. Use
`--dry-run` to validate the manifest and report schema without a key, worker, or
network. Checked-in fixture hashes are verified before use. A live report
records audio and manifest hashes but never includes a provider transcript.
WER/CER normalization ignores Unicode case, punctuation, and spacing. The
harness repeats every clip/transport five times by default so one provider
result cannot define the release metric. Reports show REST and streaming WER
separately as well as the combined micro-average; the combined value contains
both transports and must not be mistaken for a larger corpus. Extended
qualification reports also break WER/CER down by clean, 10 dB office-noise, and
5 dB office-noise conditions.
Thresholds are advisory unless `--enforce` is supplied; for example:

```sh
python3 tests/deepgram_benchmark/benchmark.py --enforce --max-wer .10 --max-cer .08
```

Enforcement always requires successful/nonempty speech, expected no-speech,
and a terminal worker result whose authoritative `transport` is `stream` for
stream-mode clips. The initial `streaming_active` ready flag only says that a
session started; a later WebSocket/finalization failure can still produce an
automatic REST result and is reported as such. Run the workflow several times
across normal provider variance before selecting thresholds. Record the model,
region, manifest hash and individual JSON artifacts used for a baseline.

Streaming timing separates connection readiness, paced audio feed duration,
total session time, and `post_stop_ms`: the time from sending the explicit
finish command until the validated final transcript arrives. `post_stop_ms` is
the closest provider-canary measurement of user-visible release-to-result
latency. REST records `request_to_result_ms` after the complete WAV exists, so
REST and total streaming duration must not be compared as equivalent intervals.
Headline latency medians use speech clips only; silence remains visible in the
per-clip evidence without skewing the representative dictation latency.

## Reading CI evidence

Open **Actions → Live Deepgram worker benchmark → the run → Summary** for a
current-versus-previous table covering WER, CER, REST request latency, stream
connection time, stream post-stop latency, total paced-stream time, transport,
and per-clip results. The workflow compares with the newest retained successful
benchmark artifact; the first run or an expired 90-day artifact has no baseline.

The **Release** workflow benchmarks its exact release commit with enforcement
enabled before publication. A release cannot publish unless REST and streaming
canaries succeed, streaming remains authoritative rather than falling back to
REST, expected speech/no-speech behavior passes, aggregate WER is at most 10%,
and aggregate CER is at most 8%. A scheduled run repeats the same enforced test
weekly on the default branch because Deepgram can change independently of a
SayAll commit. Latency remains measured and advisory until enough history exists
to establish a stable threshold. Ordinary pushes and pull requests do not run
the live benchmark or receive its provider secret. To evaluate a branch
separately, manually run **Live Deepgram worker benchmark** from the Actions tab
and select that branch. Select **qualification** for the extended clean and
noise corpus, or **representative** to download and run the pinned AMI workplace
corpus in both Verbatim and Clean modes. The two options should be run
separately. Manual runs are advisory by default but can enable enforcement with
thresholds chosen for that corpus.

Download the `deepgram-benchmark-<run>-<attempt>` artifact and open
`benchmark-report.html` for the same tables plus every macOS and Linux HUD PNG
from the successful CI run at the benchmarked commit. The raw privacy-safe data
is in `deepgram-benchmark.json`; `benchmark-comparison.md` is the exact job
summary. Live provider results remain separate from ordinary PR CI so untrusted
pull requests never receive the benchmark secret and normal code changes do not
spend provider quota automatically.

## Extending speech coverage

Add consented recordings or clearly CC-licensed material to a new versioned
manifest. Each clip must identify its source path/recipe, expected transcript,
language, no-speech expectation, provenance, license, and SHA-256; verify
checked-in bytes against that hash in review. Do not rewrite an established
manifest or add recordings of uncertain origin. Keep separate condition groups
for clean speech, ordinary environmental noise, competing speech, accents, and
microphone/acoustic playback so one aggregate does not hide the failure mode.

For a frozen release candidate, manually dispatch the separate workflow at the
exact candidate commit, retain its JSON artifact, compare repeated runs with
the established baseline, and treat anomalies as investigation signals—not as
authorization to release. Physical supported-platform qualification remains
mandatory.
