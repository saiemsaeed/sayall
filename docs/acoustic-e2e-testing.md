# Acoustic end-to-end testing

The acoustic runner sends a prerecorded speech fixture through a private debug
source at real-time speed. It exercises the native HUD lifecycle, streaming
worker, Deepgram, the selected processing mode, delivery boundary, and
transcript scoring without opening a physical microphone or changing the
clipboard.

This is deterministic pipeline coverage, not a substitute for a physical
microphone smoke test. Run one physical check for each supported microphone
class before a stable release.

## Fixture requirements

Use an uncompressed 16 kHz, mono, 16-bit PCM WAV and an authoritative UTF-8
transcript. Fixtures and generated reports may contain speech or transcripts;
keep private material out of the repository and CI artifacts.

The local LibriSpeech fixtures prepared under `dist/manual-acoustic-e2e-v1`
can be run as follows:

```sh
python3 tests/acoustic_e2e/run.py \
  --fixture dist/manual-acoustic-e2e-v1/normalized-wav/2277-149896-0000.wav \
  --reference dist/manual-acoustic-e2e-v1/2277-149896-0000.txt \
  --mode verbatim --runs 3
```

The runner reads the existing SayAll configuration, copies it into a private
temporary directory, forces streaming and the requested processing mode, and
deletes the copy after completion. Environment API-key overrides continue to
work. It builds and launches an isolated debug HUD; the installed SayAll app,
its control socket, microphone selection, and clipboard are untouched.

Reports are written beneath `dist/acoustic-e2e/`. A run fails when aggregate
WER exceeds 0.35 or aggregate CER exceeds 0.20. Override these thresholds with
`--max-wer` and `--max-cer` when evaluating a new corpus.

Run Verbatim first to measure transcription accuracy. Clean and Polished are
additional transformation checks and can intentionally differ from a verbatim
reference.

## Noisy corpus

Do not use only clean studio speech for release qualification. Build
reproducible noisy variants from a licensed clean corpus with:

```sh
python3 tests/acoustic_e2e/augment.py \
  --source-manifest dist/manual-acoustic-e2e-v1/manifest.json \
  --output dist/acoustic-e2e/noisy-corpus-v1
```

For every source utterance, this produces a clean control, nearby English
speech at 10 dB and 5 dB signal-to-noise ratios, and deterministic office-like
HVAC and keyboard noise at 8 dB. The generated manifest records every recipe,
background speech source, and WAV digest. Generated audio remains under
`dist/`; do not commit it. Run each manifest case through `run.py` using its
`wav` and `reference` paths.

These injected variants test the native and transcription pipeline under
controlled interference. They do not model microphone hardware, room echoes,
or acoustic playback, so retain a short physical microphone smoke test.
