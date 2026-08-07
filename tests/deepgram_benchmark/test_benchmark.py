import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from unittest import mock
from benchmark import ProtocolError, aggregate, classify, edit_distance, error_counts, main, make_audio, nonnegative_finite, normalize, positive_finite, read_line, thresholds_pass, validate_ready, validate_result, worker_identity

class MetricsTests(unittest.TestCase):
    def test_normalize(self): self.assertEqual(normalize(" HéLLo,\tWORLD! "), "héllo world")
    def test_edit_distance_and_error_counts(self):
        self.assertEqual(edit_distance("kitten", "sitting"), 3)
        self.assertEqual(error_counts("one two three", "one too three")["word_edits"], 1)
    def test_aggregate_is_micro_average(self):
        got = aggregate([error_counts("a b", "a"), error_counts("c", "x")])
        self.assertEqual(got["word_edits"], 2); self.assertAlmostEqual(got["wer"], 2/3)
    def test_classification(self):
        self.assertEqual(classify(False, {"status":"success", "text":"Hi."}), "speech_ok")
        self.assertEqual(classify(True, {"status":"success", "text":"ghost"}), "false_speech")
        self.assertEqual(classify(True, {"status":"no_speech"}), "expected_no_speech")
        self.assertEqual(classify(True, {}), "invalid_result")
        self.assertEqual(classify(False, {"harness_error":"timeout"}), "harness_error")
    def test_thresholds(self):
        clips = [{"classification":"speech_ok"}, {"classification":"expected_no_speech"}]
        self.assertTrue(thresholds_pass(clips, {"wer":.2,"cer":.1}, .3, .2))
        self.assertFalse(thresholds_pass(clips, {"wer":.4,"cer":.1}, .3, .2))
        self.assertFalse(thresholds_pass([{"classification":"missing_speech"}], {"wer":0,"cer":0}))
        self.assertFalse(thresholds_pass([{"classification":"speech_ok", "mode":"stream", "effective_transport":"rest"}], {"wer":0,"cer":0}))
    def test_protocol_validation_requires_authoritative_transport(self):
        validate_ready({"version":1, "event":"ready", "streaming":True})
        validate_result({"version":1, "status":"success", "text":"hello", "transport":"stream"})
        with self.assertRaises(RuntimeError): validate_result({"version":1, "status":"success", "text":"hello"})
        with self.assertRaises(RuntimeError): validate_result({"version":1, "status":"no_speech", "text":"" , "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({"version":1, "status":"error", "error":"secret provider body", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({"version":1, "status":"success", "text":"hello", "error":"secret", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({"version":1, "status":"no_speech", "error":"secret", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({"version":1, "status":"error", "text":["secret"], "error":"internal", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({"version":1, "status":"error", "error":[], "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_ready(["not", "an", "object"])

    def test_dry_run_needs_no_worker_key_or_synthesis_tools(self):
        manifest = pathlib.Path(__file__).with_name("manifest-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "report.json"
            self.assertEqual(main(["--dry-run", "--manifest", str(manifest), "--output", str(output)]), 0)
            report = json.loads(output.read_text())
        self.assertEqual(report["execution"], "dry_run")
        self.assertIsNone(report["worker_build"])
        self.assertEqual(len(report["clips"]), 6)
        self.assertTrue(all("recipe_sha256" in clip["source"] for clip in report["clips"]))
        self.assertTrue(all("audio_sha256" not in clip for clip in report["clips"]))

    def test_dry_run_ignores_enforcement_and_rejects_invalid_numbers(self):
        manifest = pathlib.Path(__file__).with_name("manifest-v1.json")
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "report.json"
            self.assertEqual(main(["--dry-run", "--enforce", "--manifest", str(manifest), "--output", str(output)]), 0)
            report = json.loads(output.read_text())
        self.assertFalse(report["thresholds"]["enforced"])
        self.assertIsNone(report["thresholds"]["passed"])
        for value in ("nan", "inf", "-1"):
            with self.assertRaises(Exception): nonnegative_finite(value)
        for value in ("nan", "inf", "0", "-1"):
            with self.assertRaises(Exception): positive_finite(value)

    def test_missing_secret_still_writes_privacy_safe_report(self):
        manifest = pathlib.Path(__file__).with_name("manifest-v1.json")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True):
            output = pathlib.Path(directory) / "report.json"
            self.assertEqual(main(["--manifest", str(manifest), "--output", str(output)]), 1)
            report = json.loads(output.read_text())
        self.assertEqual(report["harness_error"], "missing_secret")
        self.assertEqual(len(report["clips"]), 6)
        self.assertTrue(all(clip["harness_error"] == "missing_secret" for clip in report["clips"]))

    def test_synthesized_audio_is_private(self):
        clip = {"id":"speech", "source":{"type":"espeak-ng", "voice":"en-us", "text":"private fixture"}}
        def fake_run(command, **_kwargs):
            if command[0] == "espeak-ng":
                raw = pathlib.Path(command[command.index("-w") + 1])
                with wave.open(str(raw), "wb") as output:
                    output.setnchannels(1); output.setsampwidth(2); output.setframerate(22050); output.writeframes(b"\0\0" * 10)
            else:
                shutil.copyfile(command[1], command[-1])
        with tempfile.TemporaryDirectory() as directory, mock.patch("benchmark.subprocess.run", side_effect=fake_run):
            wav_path, _ = make_audio(clip, pathlib.Path(directory))
            self.assertEqual(wav_path.stat().st_mode & 0o777, 0o600)

    def test_identity_projects_only_validated_public_fields(self):
        completed = subprocess.CompletedProcess([], 0, stdout=b'{"protocol_version":1,"build_version":"0.2.10","untrusted":"drop me"}\n')
        with mock.patch("benchmark.subprocess.run", return_value=completed):
            self.assertEqual(worker_identity(pathlib.Path("worker")), {"protocol_version":1, "build_version":"0.2.10"})
        completed.stdout = b'["invalid"]\n'
        with mock.patch("benchmark.subprocess.run", return_value=completed), self.assertRaises(ProtocolError):
            worker_identity(pathlib.Path("worker"))

    def test_partial_stream_frame_obeys_deadline(self):
        process = subprocess.Popen([sys.executable, "-c", "import sys,time; sys.stdout.write('{'); sys.stdout.flush(); time.sleep(5)"],
                                   stdout=subprocess.PIPE)
        try:
            with self.assertRaises(TimeoutError): read_line(process, 0.05)
        finally:
            process.kill(); process.wait(); process.stdout.close()

if __name__ == "__main__": unittest.main()
