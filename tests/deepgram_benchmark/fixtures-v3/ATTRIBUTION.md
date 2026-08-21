# Extended LibriSpeech qualification fixtures

The additional utterances in this directory are from the **LibriSpeech ASR
corpus, clean validation split**, distributed under the
[Creative Commons Attribution 4.0 International license](https://creativecommons.org/licenses/by/4.0/).

Source corpus: <https://www.openslr.org/12>

The source row, speaker, chapter, transcript, source WAV SHA-256, deterministic
noise recipe, and canonical generated-audio SHA-256 are recorded in
[`../manifest-v3.json`](../manifest-v3.json). The source audio is normalized to
uncompressed mono 16 kHz signed 16-bit PCM. Office-noise variants are generated
deterministically by the benchmark harness and do not alter the attribution or
reference transcript.

LibriSpeech citation:

> Vassil Panayotov, Guoguo Chen, Daniel Povey and Sanjeev Khudanpur,
> “LibriSpeech: an ASR corpus based on public domain audio books,” ICASSP 2015.
