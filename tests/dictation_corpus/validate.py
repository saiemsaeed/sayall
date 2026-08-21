#!/usr/bin/env python3
"""Validate a consented in-domain SayAll dictation benchmark manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import unicodedata
import wave

SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
REQUIRED_CATEGORIES = {"everyday", "long_form", "technical", "disfluent"}


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    text = "".join(" " if unicodedata.category(c).startswith(("P", "Z")) else c for c in text)
    return " ".join(text.split())


def canonical_wav(path: pathlib.Path) -> None:
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError(f"{path} must be mono 16 kHz signed-16 PCM WAV")
        if audio.getnframes() < 4800:
            raise ValueError(f"{path} must contain at least 300 ms of audio")


def contained(root: pathlib.Path, relative: object) -> pathlib.Path:
    if not isinstance(relative, str) or not relative:
        raise ValueError("audio source path must be a nonempty manifest-relative string")
    path = (root / relative).resolve(strict=True)
    try:
        path.relative_to(root.resolve())
    except ValueError as error:
        raise ValueError("audio source escapes the manifest directory") from error
    return path


def validate(document: dict, root: pathlib.Path, minimum_words: int = 2000,
             minimum_speakers: int = 3) -> dict:
    clips = document.get("clips")
    if not isinstance(clips, list) or not clips:
        raise ValueError("manifest clips must be a nonempty array")
    identifiers, speakers, categories = set(), set(), set()
    word_count = 0
    for clip in clips:
        identifier = clip.get("id")
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier) or identifier in identifiers:
            raise ValueError("clip IDs must be unique safe path components")
        identifiers.add(identifier)
        speaker = clip.get("speaker_id")
        if not isinstance(speaker, str) or not SAFE_ID.fullmatch(speaker):
            raise ValueError(f"clip {identifier} has an invalid speaker_id")
        speakers.add(speaker)
        category = clip.get("category")
        if category not in REQUIRED_CATEGORIES:
            raise ValueError(f"clip {identifier} has an unsupported category")
        categories.add(category)
        if clip.get("consent") is not True or not isinstance(clip.get("license"), str) or not clip["license"]:
            raise ValueError(f"clip {identifier} requires explicit consent and license metadata")
        verbatim, clean = clip.get("verbatim_reference"), clip.get("clean_reference")
        if not isinstance(verbatim, str) or not normalize(verbatim):
            raise ValueError(f"clip {identifier} requires a verbatim_reference")
        if not isinstance(clean, str) or not normalize(clean):
            raise ValueError(f"clip {identifier} requires a clean_reference")
        word_count += len(normalize(verbatim).split())
        clean_normalized = normalize(clean)
        protected = clip.get("protected_terms", [])
        if not isinstance(protected, list) or any(not isinstance(term, str) or not normalize(term) for term in protected):
            raise ValueError(f"clip {identifier} has invalid protected_terms")
        for term in protected:
            if normalize(term) not in clean_normalized:
                raise ValueError(f"clip {identifier} clean_reference omits protected term {term!r}")
        source = clip.get("source")
        if not isinstance(source, dict) or source.get("type") != "wav":
            raise ValueError(f"clip {identifier} source must be a WAV object")
        path = contained(root, source.get("path"))
        canonical_wav(path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if source.get("wav_sha256") != digest:
            raise ValueError(f"clip {identifier} WAV hash does not match")
    if word_count < minimum_words:
        raise ValueError(f"corpus has {word_count} verbatim words; at least {minimum_words} are required")
    if len(speakers) < minimum_speakers:
        raise ValueError(f"corpus has {len(speakers)} speakers; at least {minimum_speakers} are required")
    missing = REQUIRED_CATEGORIES - categories
    if missing:
        raise ValueError("corpus is missing categories: " + ", ".join(sorted(missing)))
    return {"clips": len(clips), "speakers": len(speakers), "verbatim_words": word_count,
            "categories": sorted(categories)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--minimum-words", type=int, default=2000)
    parser.add_argument("--minimum-speakers", type=int, default=3)
    args = parser.parse_args(argv)
    if args.minimum_words < 1 or args.minimum_speakers < 1:
        parser.error("minimums must be positive")
    manifest = args.manifest.resolve(strict=True)
    result = validate(json.loads(manifest.read_text()), manifest.parent,
                      args.minimum_words, args.minimum_speakers)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
