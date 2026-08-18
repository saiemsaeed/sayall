#!/usr/bin/env python3
"""Build reproducible noisy variants of a canonical speech corpus."""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import pathlib
import random
import wave


SAMPLE_RATE = 16_000


def read_wav(path: pathlib.Path) -> list[int]:
    with wave.open(str(path), "rb") as audio:
        if (
            audio.getnchannels() != 1
            or audio.getsampwidth() != 2
            or audio.getframerate() != SAMPLE_RATE
            or audio.getcomptype() != "NONE"
        ):
            raise ValueError(f"{path} must be uncompressed 16 kHz mono 16-bit WAV")
        samples = array.array("h", audio.readframes(audio.getnframes()))
    if not samples:
        raise ValueError(f"{path} is empty")
    return list(samples)


def write_wav(path: pathlib.Path, samples: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = array.array("h", samples)
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(SAMPLE_RATE)
        audio.writeframes(payload.tobytes())
    path.chmod(0o600)


def rms(samples: list[float] | list[int]) -> float:
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def repeat_with_offset(samples: list[int], length: int, offset: int) -> list[int]:
    return [samples[(offset + index) % len(samples)] for index in range(length)]


def mix_at_snr(target: list[int], noise: list[int], snr_db: float) -> list[int]:
    if len(target) != len(noise) or not target:
        raise ValueError("target and noise must be non-empty and equal length")
    target_rms = rms(target)
    noise_rms = rms(noise)
    if target_rms == 0 or noise_rms == 0:
        raise ValueError("target and noise must contain signal")
    noise_gain = target_rms / (noise_rms * 10 ** (snr_db / 20))
    mixed = [target[index] + noise[index] * noise_gain for index in range(len(target))]
    peak = max(abs(sample) for sample in mixed)
    output_gain = min(1.0, 32_000 / peak) if peak else 1.0
    return [round(sample * output_gain) for sample in mixed]


def office_noise(length: int, seed: int) -> list[int]:
    generator = random.Random(seed)
    filtered = 0.0
    samples = []
    click_interval = int(SAMPLE_RATE * 0.47)
    for index in range(length):
        filtered = 0.94 * filtered + 0.06 * generator.uniform(-1, 1)
        seconds = index / SAMPLE_RATE
        hum = 0.35 * math.sin(2 * math.pi * 60 * seconds)
        hum += 0.15 * math.sin(2 * math.pi * 120 * seconds)
        click_position = index % click_interval
        click = 0.0
        if click_position < 240:
            click = (1 - click_position / 240) * generator.uniform(-1, 1) * 1.8
        samples.append(round((filtered + hum + click) * 6_000))
    return samples


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_corpus(source_manifest: pathlib.Path, output: pathlib.Path) -> pathlib.Path:
    document = json.loads(source_manifest.read_text())
    clips = document.get("clips", [])
    if len(clips) < 2:
        raise ValueError("at least two clean clips are required for background speech")
    source_root = source_manifest.parent / "normalized-wav"
    clean = [(clip, read_wav(source_root / f"{clip['id']}.wav")) for clip in clips]
    output.mkdir(parents=True, exist_ok=True)
    cases = []
    for index, (clip, target) in enumerate(clean):
        reference = clip["expected_transcript"]
        background_clip, background = clean[(index + 1) % len(clean)]
        background = repeat_with_offset(background, len(target), SAMPLE_RATE // 3)
        variants = (
            ("clean", target, None, None),
            ("nearby-speech-10db", mix_at_snr(target, background, 10), 10, background_clip["id"]),
            ("nearby-speech-5db", mix_at_snr(target, background, 5), 5, background_clip["id"]),
            ("office-8db", mix_at_snr(target, office_noise(len(target), index + 1), 8), 8, None),
        )
        for condition, samples, snr_db, background_id in variants:
            case_id = f"{clip['id']}--{condition}"
            wav_path = output / f"{case_id}.wav"
            reference_path = output / f"{case_id}.txt"
            write_wav(wav_path, samples)
            reference_path.write_text(reference + "\n")
            reference_path.chmod(0o600)
            cases.append({
                "id": case_id,
                "source_clip": clip["id"],
                "condition": condition,
                "snr_db": snr_db,
                "background_clip": background_id,
                "wav": wav_path.name,
                "reference": reference_path.name,
                "wav_sha256": sha256(wav_path),
            })
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps({
        "schema_version": 1,
        "source_manifest": str(source_manifest),
        "source_license": document.get("license"),
        "sample_rate": SAMPLE_RATE,
        "cases": cases,
    }, indent=2) + "\n")
    manifest_path.chmod(0o600)
    return manifest_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    print(build_corpus(args.source_manifest.resolve(strict=True), args.output.resolve()))


if __name__ == "__main__":
    main()
