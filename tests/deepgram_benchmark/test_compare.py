import json
import pathlib
import tempfile
import unittest
from types import SimpleNamespace
from compare import main, markdown_report, summarize

def report(rest=700, post=250, wer=.1):
    return {"execution":"live", "harness_error":None, "harness_version":"1.1.0", "date_utc":"2026-08-08T00:00:00Z",
            "model":"nova-3", "region":"global", "corpus_id":"canary", "manifest_schema_version":1,
            "manifest_sha256":"abc", "modes":["rest","stream"], "worker_build":{"build_version":"0.2.10"},
            "thresholds":{"passed":True}, "corpus":{"wer":wer,"cer":wer/2}, "clips":[
        {"id":"speech","mode":"rest","classification":"speech_ok","effective_transport":"rest","elapsed_ms":rest,"request_to_result_ms":rest,"wer":wer},
        {"id":"speech","mode":"stream","classification":"speech_ok","effective_transport":"stream","streaming_active":True,"elapsed_ms":2500,"audio_duration_ms":2100,"audio_feed_ms":2110,"stream_ready_ms":120,"post_stop_ms":post,"wer":wer},
    ]}

class ComparisonTests(unittest.TestCase):
    def test_summary_and_change_table(self):
        self.assertEqual(summarize(report())["post_stop_ms"], 250)
        args = SimpleNamespace(current_run_url="https://current", previous_run_url="https://previous", ui_run_url="https://ui")
        rendered = markdown_report(report(650, 200, .08), report(), args)
        self.assertIn("Stream speech finish → final transcript", rendered)
        self.assertIn("-50.00 ms better", rendered)
        self.assertIn("-2.00 pp better", rendered)

    def test_rest_fallback_cannot_pollute_streaming_medians(self):
        fixture = report()
        fixture["clips"].append({"id":"fallback","mode":"stream","classification":"speech_ok",
                                 "effective_transport":"rest","streaming_active":True,
                                 "elapsed_ms":99999,"post_stop_ms":99999})
        summary = summarize(fixture)
        self.assertEqual(summary["post_stop_ms"], 250)
        self.assertEqual(summary["stream_total_ms"], 2500)

    def test_v1_report_is_comparable_without_new_submetrics(self):
        current, previous = report(), report()
        previous["harness_version"] = "1.0.0"
        for clip in previous["clips"]:
            clip.pop("request_to_result_ms", None); clip.pop("stream_ready_ms", None)
            clip.pop("audio_duration_ms", None); clip.pop("audio_feed_ms", None); clip.pop("post_stop_ms", None)
        args = SimpleNamespace(current_run_url="", previous_run_url="", ui_run_url="")
        rendered = markdown_report(current, previous, args)
        self.assertIn("| REST speech request → result | 700 ms | 700 ms | no change |", rendered)
        self.assertIn("| Stream speech finish → final transcript | 250 ms | — | — |", rendered)

    def test_incompatible_manifest_suppresses_deltas(self):
        previous = report(); previous["manifest_sha256"] = "different"
        args = SimpleNamespace(current_run_url="", previous_run_url="", ui_run_url="")
        rendered = markdown_report(report(), previous, args)
        self.assertIn("manifest_sha256 differs", rendered)
        self.assertIn("not comparable", rendered)

    def test_html_report_embeds_hud_images(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); hud = root / "hud"; hud.mkdir()
            (hud / "recording.png").write_bytes(b"png fixture")
            current = root / "current.json"; current.write_text(json.dumps(report()))
            markdown, output = root / "summary.md", root / "report.html"
            self.assertEqual(main(["--current",str(current),"--hud-dir",str(hud),"--markdown",str(markdown),"--html",str(output)]), 0)
            self.assertIn("data:image/png;base64", output.read_text())
            self.assertIn("recording.png", output.read_text())

    def test_missing_current_still_generates_inspectable_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory); markdown, output = root / "summary.md", root / "report.html"
            self.assertEqual(main(["--current",str(root/"missing.json"),"--markdown",str(markdown),"--html",str(output)]), 0)
            self.assertIn("benchmark_not_run", markdown.read_text())
            self.assertIn("benchmark_not_run", output.read_text())

if __name__ == "__main__": unittest.main()
