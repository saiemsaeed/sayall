import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import wave
from unittest import mock
from benchmark import ProtocolError, aggregate, classify, edit_distance, error_counts, main, make_audio, nonnegative_finite, normalize, positive_finite, read_line, run_worker, thresholds_pass, validate_ready, validate_result, worker_identity

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
        base = {"version":3, "processing_profile":"verbatim"}
        validate_ready({"version":3, "event":"ready", "streaming":True})
        validate_result({**base, "status":"success", "text":"hello", "transport":"stream"})
        with self.assertRaises(RuntimeError): validate_result({**base, "status":"success", "text":"hello"})
        with self.assertRaises(RuntimeError): validate_result({"version":3, "status":"success", "text":"hello", "transport":"rest"})
        with self.assertRaises(RuntimeError): validate_result({**base, "status":"no_speech", "text":"" , "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({**base, "status":"error", "error":"secret provider body", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({**base, "status":"success", "text":"hello", "error":"secret", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({**base, "status":"no_speech", "error":"secret", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({**base, "status":"error", "text":["secret"], "error":"internal", "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_result({**base, "status":"error", "error":[], "transport":"rest"})
        with self.assertRaises(ProtocolError): validate_ready(["not", "an", "object"])

    def test_dry_run_needs_no_worker_key_or_synthesis_tools(self):
        manifest = pathlib.Path(__file__).with_name("manifest-v2.json")
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "report.json"
            self.assertEqual(main(["--dry-run", "--manifest", str(manifest), "--output", str(output)]), 0)
            report = json.loads(output.read_text())
        self.assertEqual(report["execution"], "dry_run")
        self.assertIsNone(report["worker_build"])
        self.assertEqual(len(report["clips"]), 8)
        self.assertTrue(all("recipe_sha256" in clip["source"] for clip in report["clips"]))
        self.assertTrue(all("audio_sha256" not in clip for clip in report["clips"]))

    def test_dry_run_ignores_enforcement_and_rejects_invalid_numbers(self):
        manifest = pathlib.Path(__file__).with_name("manifest-v2.json")
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
        manifest = pathlib.Path(__file__).with_name("manifest-v2.json")
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {}, clear=True):
            output = pathlib.Path(directory) / "report.json"
            self.assertEqual(main(["--manifest", str(manifest), "--output", str(output)]), 1)
            report = json.loads(output.read_text())
        self.assertEqual(report["harness_error"], "missing_secret")
        self.assertEqual(len(report["clips"]), 8)
        self.assertTrue(all(clip["harness_error"] == "missing_secret" for clip in report["clips"]))

    def test_frozen_human_fixture_is_verified_and_copied_privately(self):
        root = pathlib.Path(__file__).parent
        manifest = json.loads((root / "manifest-v2.json").read_text())
        clip = manifest["clips"][0]
        with tempfile.TemporaryDirectory() as directory:
            wav_path, pcm = make_audio(clip, pathlib.Path(directory), root)
            self.assertGreater(len(pcm), 0)
            self.assertEqual(wav_path.stat().st_mode & 0o777, 0o600)
        changed = {**clip, "source": {**clip["source"], "wav_sha256": "0" * 64}}
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            make_audio(changed, pathlib.Path(directory), root)

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
        completed = subprocess.CompletedProcess([], 0, stdout=b'{"protocol_version":3,"build_version":"0.2.10","untrusted":"drop me"}\n')
        with mock.patch("benchmark.subprocess.run", return_value=completed):
            self.assertEqual(worker_identity(pathlib.Path("worker")), {"protocol_version":3, "build_version":"0.2.10"})
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

    def test_stream_timing_separates_ready_feed_and_post_stop(self):
        script = """#!/usr/bin/env python3
import json, sys, time
if '--stream' not in sys.argv:
    json.load(sys.stdin); print(json.dumps({'version':3,'status':'success','text':'ok','processing_profile':'verbatim','transport':'rest'})); raise SystemExit
json.loads(sys.stdin.readline()); print(json.dumps({'version':3,'event':'ready','streaming':True}), flush=True)
json.loads(sys.stdin.readline()); time.sleep(0.03)
print(json.dumps({'version':3,'status':'success','text':'ok','processing_profile':'verbatim','transport':'stream'}), flush=True)
"""
        real_validate = validate_result
        def delayed_validate(frame):
            time.sleep(0.03)
            real_validate(frame)
        with tempfile.TemporaryDirectory() as directory, mock.patch("benchmark.validate_result", side_effect=delayed_validate):
            worker = pathlib.Path(directory) / "worker"
            worker.write_text(script); worker.chmod(0o700)
            pcm_path = pathlib.Path(directory) / "growing.pcm"
            request = {"pcm_path":str(pcm_path), "stream_finalize_timeout_ms":5000}
            result, active, timing = run_worker(worker, "stream", request, b"\0" * 3200, 2)
        self.assertEqual(result["transport"], "stream"); self.assertTrue(active)
        self.assertEqual(timing["audio_duration_ms"], 100)
        self.assertGreaterEqual(timing["audio_feed_ms"], 90); self.assertLess(timing["audio_feed_ms"], 180)
        self.assertGreaterEqual(timing["post_stop_ms"], 50)
        self.assertGreaterEqual(timing["elapsed_ms"], timing["post_stop_ms"] + timing["audio_feed_ms"])
        self.assertIsNone(timing["request_to_result_ms"])

if __name__ == "__main__": unittest.main()
