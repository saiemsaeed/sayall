"""Privacy-safe transcript scoring shared by the acoustic runner tests."""

from __future__ import annotations

import unicodedata


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    text = "".join(
        " " if unicodedata.category(character).startswith(("P", "Z")) else character
        for character in text
    )
    return " ".join(text.split())


def edit_distance(reference: list[str], actual: list[str]) -> int:
    previous = list(range(len(actual) + 1))
    for index, expected in enumerate(reference, 1):
        current = [index]
        for other_index, observed in enumerate(actual, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[other_index] + 1,
                    previous[other_index - 1] + (expected != observed),
                )
            )
        previous = current
    return previous[-1]


def score(reference_raw: str, actual_raw: str) -> dict:
    reference = normalize(reference_raw)
    actual = normalize(actual_raw)
    reference_words = reference.split()
    actual_words = actual.split()
    reference_chars = list(reference.replace(" ", ""))
    actual_chars = list(actual.replace(" ", ""))
    word_edits = edit_distance(reference_words, actual_words)
    char_edits = edit_distance(reference_chars, actual_chars)
    wer = word_edits / len(reference_words) if reference_words else 0.0
    cer = char_edits / len(reference_chars) if reference_chars else 0.0
    return {
        "word_edits": word_edits,
        "reference_words": len(reference_words),
        "wer": wer,
        "word_accuracy_percent": max(0.0, 1.0 - wer) * 100.0,
        "char_edits": char_edits,
        "reference_chars": len(reference_chars),
        "cer": cer,
        "character_accuracy_percent": max(0.0, 1.0 - cer) * 100.0,
    }


def aggregate(results: list[dict]) -> dict:
    word_edits = sum(result["word_edits"] for result in results)
    reference_words = sum(result["reference_words"] for result in results)
    char_edits = sum(result["char_edits"] for result in results)
    reference_chars = sum(result["reference_chars"] for result in results)
    wer = word_edits / reference_words if reference_words else 0.0
    cer = char_edits / reference_chars if reference_chars else 0.0
    return {
        "word_edits": word_edits,
        "reference_words": reference_words,
        "wer": wer,
        "word_accuracy_percent": max(0.0, 1.0 - wer) * 100.0,
        "char_edits": char_edits,
        "reference_chars": reference_chars,
        "cer": cer,
        "character_accuracy_percent": max(0.0, 1.0 - cer) * 100.0,
    }
