# SayAll in-domain speech corpus

This directory defines the primary SayAll Clean-mode quality gate. The corpus is
built from authentic, licensed workplace speech in the
[AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/), rather than from
synthetic voices or audiobook narration.

## Primary AMI corpus

`build_ami.py` downloads individual-headset utterances from the official
[`edinburghcstr/ami`](https://huggingface.co/datasets/edinburghcstr/ami)
dataset mirror. It uses one female participant (`FEE005`) and one male
participant (`MEE008`) from the four ES2002 product-design meetings. Utterances
from only one participant are joined with 200 ms silence into independent
20–40 second sessions. A joined clip never mixes speakers.

The default build contains at least 2,000 normalized words, approximately equal
speaker contributions, and authentic fillers, repetitions, false starts, and
workplace/technical language. The source dataset revision is pinned. Each
output WAV and the manifest are SHA-256 verified.

Build and validate it with:

```sh
python3 tests/dictation_corpus/build_ami.py \
  --output dist/ami-dictation-v1
python3 tests/dictation_corpus/validate.py \
  dist/ami-dictation-v1/manifest.json
```

The builder uses only Python's standard library. It downloads the required
short source utterances on demand and converts the dataset server's mono IEEE
float WAV files to mono 16 kHz signed-16 PCM. Generated audio remains under
`dist/` and is not committed.

Run the live REST and streaming benchmark with both product profiles:

```sh
python3 tests/deepgram_benchmark/benchmark.py \
  --manifest dist/ami-dictation-v1/manifest.json \
  --processing-profiles verbatim,clean --mode both --runs 3
```

Clean is the primary profile. Verbatim is retained as the raw STT diagnostic.
The builder derives `verbatim_reference` from AMI's human transcription and a
separate `clean_reference` using the product's conservative rules: `um`, `uh`, `er`, `erm`, and exact
adjacent multi-word repetitions are removed, while one-word repetitions and
other vocalizations are retained. Technical terms and numbers found in the Clean
reference are protected with zero tolerance.

Before treating a result as release evidence, inspect the generated manifest
and a sample of its audio/reference pairs. AMI transcripts are human-produced,
but forced alignment and corpus transcription conventions can still contain
errors.

## License and provenance

AMI audio and annotations are distributed under **CC BY 4.0**. Retain this
attribution when storing or redistributing generated clips:

> AMI Meeting Corpus, University of Edinburgh Centre for Speech Technology
> Research. Licensed under CC BY 4.0.

The manifest records the source dataset, pinned revision, meeting IDs, original
audio IDs, speaker IDs, license, attribution, and generated WAV hashes.

## Limitations

AMI is spontaneous workplace meeting speech, not direct personal-computer
dictation. Joining independently transcribed utterances creates a representative
short single-speaker session but does not claim that the joined sequence was
spoken continuously. Individual-headset speech is much closer to the product
than audiobook narration, but a small physical laptop-microphone corpus remains
valuable for final device qualification.

`recording-scripts-v1.json` and `recording-scripts-v1.md` remain available for
that supplementary two-speaker device corpus. `scenarios-v1.json` can be used
for later spontaneous recordings. Do not include private names, credentials,
customer information, or other sensitive content.

## Validation policy

The validator rejects fewer than 2,000 normalized verbatim words, fewer than
two speakers, missing scenario categories, unsafe paths, noncanonical audio,
hash mismatches, missing dual references, and unprotected Clean references.
For manifests declaring `session_policy`, it also verifies every clip is within
the declared duration bounds and reports total and average audio duration.
Generated 10 dB and 5 dB noise variants do not increase the unique corpus word
count.
