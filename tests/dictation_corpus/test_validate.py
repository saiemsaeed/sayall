import hashlib
import json
import pathlib
import tempfile
import unittest
import wave

from build_ami import category_for, clean_reference, group_rows, normalized_word_count
from validate import normalize, validate


class CorpusValidationTests(unittest.TestCase):
    def test_ami_cleanup_and_grouping_are_deterministic(self):
        transcript = "UM WE SHOULD WE SHOULD KEEP THE THE JAVA FILE"
        self.assertEqual(clean_reference(transcript), "we should keep the the java file")
        self.assertEqual(category_for(transcript), "technical")
        self.assertEqual(normalized_word_count("DON'T CHANGE S. S. H."), 6)
        rows = [{"begin_time": index * 10, "end_time": index * 10 + 8} for index in range(7)]
        groups = group_rows(rows)
        self.assertEqual([len(group) for group in groups], [4, 3])

    def test_recording_pack_exceeds_target_and_balances_two_characters(self):
        pack = json.loads(pathlib.Path(__file__).with_name("recording-scripts-v1.json").read_text())
        totals = {}
        for script in pack["scripts"]:
            totals[script["character"]] = totals.get(script["character"], 0) + len(normalize(script["verbatim_reference"]).split())
            clean = normalize(script["clean_reference"])
            for term in script["protected_terms"]:
                self.assertIn(normalize(term), clean)
        self.assertGreaterEqual(sum(totals.values()), 2000)
        self.assertEqual(set(totals), {"Maya", "Daniel"})
        self.assertLess(abs(totals["Maya"] - totals["Daniel"]), 100)
        self.assertTrue(any(s["verbatim_reference"] != s["clean_reference"] for s in pack["scripts"]))

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
                "protected_terms":["protected term"], "sha256":digest,
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
            document = self.fixture(root)
            document["session_policy"] = {"minimum_seconds": 20, "maximum_seconds": 40}
            with self.assertRaisesRegex(ValueError, "between 20 and 40 seconds"):
                validate(document, root, minimum_words=1, minimum_speakers=1)


if __name__ == "__main__": unittest.main()
