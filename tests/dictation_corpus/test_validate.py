import hashlib
import json
import pathlib
import tempfile
import unittest
import wave

from validate import validate


class CorpusValidationTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path) -> dict:
        audio = root / "sample.wav"
        with wave.open(str(audio), "wb") as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
            output.writeframes(b"\0\0" * 8000)
        digest = hashlib.sha256(audio.read_bytes()).hexdigest()
        clips = []
        for index, category in enumerate(("everyday", "long_form", "technical", "disfluent")):
            clips.append({"id":f"clip-{index}", "speaker_id":f"speaker-{index}",
                "category":category, "consent":True, "license":"CC BY 4.0",
                "verbatim_reference":"the the protected term", "clean_reference":"the protected term",
                "protected_terms":["protected term"],
                "source":{"type":"wav", "path":"sample.wav", "wav_sha256":digest}})
        return {"clips":clips}

    def test_accepts_dual_reference_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); document = self.fixture(root)
            result = validate(document, root, minimum_words=12, minimum_speakers=3)
        self.assertEqual(result["clips"], 4)
        self.assertEqual(result["verbatim_words"], 16)

    def test_rejects_missing_words_protection_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); document = self.fixture(root)
            with self.assertRaisesRegex(ValueError, "at least 100"):
                validate(document, root, minimum_words=100, minimum_speakers=3)
            document["clips"][0]["clean_reference"] = "the term"
            with self.assertRaisesRegex(ValueError, "omits protected term"):
                validate(document, root, minimum_words=1, minimum_speakers=1)
            document = self.fixture(root); document["clips"][0]["source"]["wav_sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "hash does not match"):
                validate(document, root, minimum_words=1, minimum_speakers=1)


if __name__ == "__main__": unittest.main()
