import array
import json
import math
import pathlib
import tempfile
import unittest
import wave

from augment import build_corpus, mix_at_snr, office_noise, rms


class AugmentationTests(unittest.TestCase):
    def test_mix_uses_requested_signal_to_noise_ratio(self):
        target = [1_000 if index % 2 else -1_000 for index in range(16_000)]
        noise = [500 * math.sin(index / 13) for index in range(16_000)]
        mixed = mix_at_snr(target, noise, 10)
        residual = [mixed[index] - target[index] for index in range(len(target))]
        measured = 20 * math.log10(rms(target) / rms(residual))
        self.assertAlmostEqual(measured, 10, delta=0.05)

    def test_office_noise_is_deterministic_and_contains_signal(self):
        first = office_noise(16_000, 7)
        self.assertEqual(first, office_noise(16_000, 7))
        self.assertNotEqual(first, office_noise(16_000, 8))
        self.assertGreater(rms(first), 100)

    def test_build_corpus_creates_each_condition_for_each_clip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            wavs = source / "normalized-wav"
            wavs.mkdir(parents=True)
            clips = []
            for index in range(2):
                identifier = f"clip-{index}"
                clips.append({"id": identifier, "expected_transcript": f"fixture {index}"})
                samples = [round(math.sin(frame / (10 + index)) * 2_000) for frame in range(8_000)]
                with wave.open(str(wavs / f"{identifier}.wav"), "wb") as audio:
                    audio.setnchannels(1)
                    audio.setsampwidth(2)
                    audio.setframerate(16_000)
                    audio.writeframes(array.array("h", samples).tobytes())
            manifest = source / "manifest.json"
            manifest.write_text(json.dumps({"license": "test", "clips": clips}))
            output_manifest = build_corpus(manifest, root / "output")
            result = json.loads(output_manifest.read_text())
            self.assertEqual(len(result["cases"]), 8)
            self.assertEqual(result["recipe"]["version"], 1)
            self.assertEqual(len(result["generator_sha256"]), 64)
            self.assertEqual(len(result["source_manifest_sha256"]), 64)
            self.assertEqual(
                {case["condition"] for case in result["cases"]},
                {"clean", "nearby-speech-10db", "nearby-speech-5db", "office-8db"},
            )
            for case in result["cases"]:
                self.assertEqual(len(case["source_wav_sha256"]), 64)
                if case["background_clip"]:
                    self.assertEqual(len(case["background_wav_sha256"]), 64)
                self.assertTrue((output_manifest.parent / case["wav"]).is_file())
                self.assertTrue((output_manifest.parent / case["reference"]).is_file())
