#!/usr/bin/env python3
"""Build the licensed AMI single-speaker SayAll benchmark corpus.

The builder downloads individual-headset utterances from the official
edinburghcstr/ami Hugging Face dataset, groups utterances from one speaker into
short dictation-like sessions, and emits canonical WAV files plus a manifest.
No network access occurs unless this program is run explicitly.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import struct
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import wave

DATASET = "edinburghcstr/ami"
DATASET_REVISION = "46f28f2503e2ec48f8867a84eef356c70476beab"
CONFIG = "ihm"
SPLIT = "train"
MEETING_PREFIX = "ES2002"
SEARCH_START = 16000
# AMI participant IDs encode reported gender in their first character. These
# speakers took part throughout one four-meeting product-design scenario.
SPEAKERS = {"FEE005": "female", "MEE008": "male"}
ROWS_ENDPOINT = "https://datasets-server.huggingface.co/rows"
LICENSE = "CC BY 4.0"
ATTRIBUTION = "AMI Meeting Corpus, University of Edinburgh CSTR"
CLEAN_FILLERS = {"um", "uh", "er", "erm"}
DISFLUENCIES = CLEAN_FILLERS | {"mm", "hmm", "mm-hmm", "uh-huh"}
TECHNICAL = {"xml", "java", "database", "interface", "file", "files", "code", "data", "hash", "memory", "ssh"}
EVERYDAY = {"meeting", "week", "weekend", "send", "email", "time", "tomorrow", "need", "want", "check"}
TOKEN = re.compile(r"[A-Za-z0-9]+(?:[.'-][A-Za-z0-9]+)*")


def words(text: str) -> list[str]:
    return [match.group(0).casefold().strip(".") for match in TOKEN.finditer(text)]


def normalized_word_count(text: str) -> int:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    normalized = "".join(" " if unicodedata.category(character).startswith(("P", "Z")) else character
                         for character in normalized)
    return len(normalized.split())


def clean_reference(text: str) -> str:
    """Expected output of SayAll's conservative Clean profile.

    AMI transcription is uppercase, while provider output is normally mixed
    case. Scoring is case-insensitive. Remove vocalized fillers and collapse
    repeated multi-word phrases; intentionally retain one-word repetitions to
    match the product's conservative cleanup engine.
    """
    tokens = words(text)
    tokens = [token for token in tokens if token not in CLEAN_FILLERS]
    for width in range(8, 1, -1):
        base = 0
        while base + width * 2 <= len(tokens):
            candidate = base + width
            if tokens[base:candidate] != tokens[candidate:candidate + width]:
                base += 1
                continue
            while candidate + width <= len(tokens) and tokens[base:base + width] == tokens[candidate:candidate + width]:
                del tokens[candidate:candidate + width]
            base = candidate
    return " ".join(tokens)


def category_for(text: str) -> str:
    tokens = words(text)
    token_set = set(tokens)
    if token_set & TECHNICAL:
        return "technical"
    disfluencies = sum(token in DISFLUENCIES for token in tokens) + sum(a == b for a, b in zip(tokens, tokens[1:]))
    if disfluencies >= 3:
        return "disfluent"
    if token_set & EVERYDAY:
        return "everyday"
    return "long_form"


def protected_terms(text: str) -> list[str]:
    present = set(words(text))
    terms = sorted(present & TECHNICAL)
    terms.extend(sorted({token for token in present if any(character.isdigit() for character in token)}))
    return terms


def fetch_rows(offset: int, length: int = 100) -> list[dict]:
    query = urllib.parse.urlencode({"dataset": DATASET, "config": CONFIG, "split": SPLIT,
                                    "offset": offset, "length": length})
    request = urllib.request.Request(f"{ROWS_ENDPOINT}?{query}", headers={"User-Agent": "SayAll-AMI-corpus-builder/1"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                document = json.load(response)
            return [entry["row"] for entry in document["rows"]]
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 5:
                raise
            time.sleep(max(float(error.headers.get("Retry-After", 0) or 0), 2 ** attempt))
    raise AssertionError("unreachable")


def download(url: str, attempts: int = 3) -> bytes:
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "SayAll-AMI-corpus-builder/1"})
            with urllib.request.urlopen(request, timeout=90) as response:
                return response.read()
        except (OSError, urllib.error.URLError):
            if attempt + 1 == attempts:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def wav_pcm16(data: bytes) -> tuple[int, bytes]:
    """Decode the PCM16 or IEEE-float mono WAV emitted by the dataset server."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("AMI asset is not a RIFF/WAVE file")
    chunks: dict[bytes, bytes] = {}
    offset = 12
    while offset + 8 <= len(data):
        name, size = struct.unpack_from("<4sI", data, offset)
        offset += 8
        chunks[name] = data[offset:offset + size]
        offset += size + (size & 1)
    if b"fmt " not in chunks or b"data" not in chunks:
        raise ValueError("AMI WAV is missing format or audio data")
    format_code, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", chunks[b"fmt "])
    if channels != 1:
        raise ValueError("AMI individual-headset asset is not mono")
    raw = chunks[b"data"]
    if format_code == 1 and bits == 16:
        return rate, raw
    if format_code == 3 and bits == 32:
        count = len(raw) // 4
        samples = struct.unpack(f"<{count}f", raw[:count * 4])
        values = [max(-32768, min(32767, round(sample * 32767))) for sample in samples]
        return rate, struct.pack(f"<{count}h", *values)
    raise ValueError(f"unsupported AMI WAV encoding {format_code}/{bits}")


def write_wav(path: pathlib.Path, pcm: bytes, rate: int = 16000) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(pcm)


def verify_revision() -> None:
    request = urllib.request.Request(f"https://huggingface.co/api/datasets/{DATASET}",
                                     headers={"User-Agent": "SayAll-AMI-corpus-builder/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        revision = json.load(response).get("sha")
    if revision != DATASET_REVISION:
        raise RuntimeError(f"AMI dataset revision changed from {DATASET_REVISION} to {revision}; review and pin it")


def collect(target_words_per_speaker: int, max_rows: int) -> dict[str, list[dict]]:
    selected = {speaker: [] for speaker in SPEAKERS}
    totals = {speaker: 0 for speaker in SPEAKERS}
    for offset in range(SEARCH_START, SEARCH_START + max_rows, 100):
        for row in fetch_rows(offset):
            speaker = row.get("speaker_id")
            text = row.get("text", "")
            duration = float(row.get("end_time", 0)) - float(row.get("begin_time", 0))
            if (speaker not in selected or not str(row.get("meeting_id", "")).startswith(MEETING_PREFIX) or totals[speaker] >= target_words_per_speaker
                    or not isinstance(text, str) or normalized_word_count(text) < 2 or not 0.3 <= duration <= 18
                    or not row.get("audio") or not row["audio"][0].get("src")):
                continue
            selected[speaker].append(row)
            totals[speaker] += normalized_word_count(text)
        if all(total >= target_words_per_speaker for total in totals.values()):
            for rows in selected.values():
                rows.sort(key=lambda row: (row["meeting_id"], float(row["begin_time"]), row["audio_id"]))
            return selected
    raise RuntimeError(f"only found AMI word totals {totals} within the first {max_rows} rows")


def group_rows(rows: list[dict], minimum: float = 20, target: float = 25, maximum: float = 40) -> list[list[dict]]:
    groups, current, duration = [], [], 0.0
    for row in rows:
        row_duration = float(row["end_time"]) - float(row["begin_time"])
        added = row_duration + (0.2 if current else 0)
        if current and duration + added > maximum:
            if duration >= minimum:
                groups.append(current)
            current, duration = [], 0.0
            added = row_duration
        current.append(row)
        duration += added
        if duration >= target:
            groups.append(current)
            current, duration = [], 0.0
    if current and duration >= minimum:
        groups.append(current)
    return groups


def build(output: pathlib.Path, minimum_words: int, max_rows: int) -> dict:
    verify_revision()
    output.mkdir(parents=True, exist_ok=True)
    audio_dir = output / "audio"
    audio_dir.mkdir(exist_ok=True)
    selected = collect((minimum_words + 1) // 2 + 350, max_rows)
    clips = []
    silence = b"\0\0" * 3200
    for speaker, rows in selected.items():
        for group_index, group in enumerate(group_rows(rows), 1):
            text = " ".join(row["text"].strip() for row in group)
            clean = clean_reference(text)
            if not clean:
                continue
            pcm_parts, source_ids = [], []
            for index, row in enumerate(group):
                rate, pcm = wav_pcm16(download(row["audio"][0]["src"]))
                if rate != 16000:
                    raise ValueError(f"AMI asset {row['audio_id']} is {rate} Hz; expected 16000 Hz")
                if index:
                    pcm_parts.append(silence)
                pcm_parts.append(pcm)
                source_ids.append(row["audio_id"])
            identifier = f"ami-{speaker.casefold()}-{group_index:02d}"
            relative = pathlib.Path("audio") / f"{identifier}.wav"
            write_wav(output / relative, b"".join(pcm_parts))
            digest = hashlib.sha256((output / relative).read_bytes()).hexdigest()
            clips.append({
                "id": identifier,
                "speaker_id": speaker,
                "speaker_gender": SPEAKERS[speaker],
                "category": category_for(text),
                "consent": True,
                "license": LICENSE,
                "attribution": ATTRIBUTION,
                "verbatim_reference": " ".join(words(text)),
                "clean_reference": clean,
                "protected_terms": protected_terms(clean),
                "language": "en-GB",
                "expect_no_speech": False,
                "provenance": {"dataset": DATASET, "config": CONFIG, "split": SPLIT,
                               "meeting_ids": sorted({row["meeting_id"] for row in group}), "audio_ids": source_ids},
                "source": {"type": "wav", "path": str(relative), "wav_sha256": digest},
                "sha256": digest,
            })
    # Keep balanced speakers and stop only at group boundaries.
    kept, totals = [], {speaker: 0 for speaker in SPEAKERS}
    required = {"everyday", "long_form", "technical", "disfluent"}
    by_speaker = {speaker: [clip for clip in clips if clip["speaker_id"] == speaker] for speaker in SPEAKERS}
    for pair in zip(*by_speaker.values()):
        for clip in pair:
            kept.append(clip)
            totals[clip["speaker_id"]] += normalized_word_count(clip["verbatim_reference"])
        if (sum(totals.values()) >= minimum_words and min(totals.values()) >= minimum_words * 0.45
                and required <= {clip["category"] for clip in kept}):
            break
    if sum(totals.values()) < minimum_words:
        raise RuntimeError(f"grouped corpus contains only {sum(totals.values())} usable words")
    categories = {clip["category"] for clip in kept}
    if not required <= categories:
        raise RuntimeError(f"selected AMI clips are missing categories: {sorted(required - categories)}")
    keep_paths = {clip["source"]["path"] for clip in kept}
    for path in audio_dir.glob("*.wav"):
        if str(path.relative_to(output)) not in keep_paths:
            path.unlink()
    manifest = {
        "schema_version": 1,
        "corpus_id": "sayall-ami-single-speaker-v1",
        "description": "Short single-speaker workplace-speech sessions derived from AMI individual-headset utterances in the ES2002 product-design scenario.",
        "primary_profile": "clean",
        "license": LICENSE,
        "attribution": ATTRIBUTION,
        "dataset_revision": DATASET_REVISION,
        "session_policy": {"minimum_seconds": 20, "maximum_seconds": 40, "target_average_seconds": 30},
        "clips": kept,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"clips": len(kept), "words": sum(totals.values()), "speaker_words": totals,
            "categories": sorted(categories), "manifest": str(output / "manifest.json")}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("dist/ami-dictation-v1"))
    parser.add_argument("--minimum-words", type=int, default=2000)
    parser.add_argument("--max-rows", type=int, default=10000)
    args = parser.parse_args(argv)
    if args.minimum_words < 1 or args.max_rows < 100:
        parser.error("minimum-words must be positive and max-rows must be at least 100")
    print(json.dumps(build(args.output, args.minimum_words, args.max_rows), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
