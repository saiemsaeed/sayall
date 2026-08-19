import json
import pathlib
import tempfile
import unittest
import wave
from unittest import mock

import run as runner


class RunnerTests(unittest.TestCase):
    def test_canonical_fixture_rewrites_wav_and_returns_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "source.wav"
            output = pathlib.Path(directory) / "output.wav"
            with wave.open(str(source), "wb") as fixture:
                fixture.setnchannels(1)
                fixture.setsampwidth(2)
                fixture.setframerate(16_000)
                fixture.writeframes(b"\x01\x00" * 8_000)
            self.assertEqual(runner.canonical_fixture(source, output), 0.5)
            with wave.open(str(output), "rb") as fixture:
                self.assertEqual(fixture.getparams().nchannels, 1)
                self.assertEqual(fixture.getparams().sampwidth, 2)
                self.assertEqual(fixture.getparams().framerate, 16_000)
                self.assertEqual(fixture.getnframes(), 8_000)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_canonical_fixture_rejects_wrong_format_and_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "source.wav"
            output = pathlib.Path(directory) / "output.wav"
            with wave.open(str(source), "wb") as fixture:
                fixture.setnchannels(2)
                fixture.setsampwidth(2)
                fixture.setframerate(16_000)
                fixture.writeframes(b"\0" * 32_000)
            with self.assertRaisesRegex(ValueError, "16 kHz mono"):
                runner.canonical_fixture(source, output)

    def test_linux_session_links_only_existing_runtime_endpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            session = root / "session"
            runtime = root / "isolated"
            session.mkdir()
            runtime.mkdir()
            (session / "wayland-test").touch()
            (session / "bus").touch()
            runner.link_linux_session(runtime, {
                "XDG_RUNTIME_DIR": str(session),
                "WAYLAND_DISPLAY": "wayland-test",
            })
            self.assertEqual((runtime / "wayland-test").resolve(), (session / "wayland-test").resolve())
            self.assertEqual((runtime / "bus").resolve(), (session / "bus").resolve())
            self.assertFalse((runtime / "pipewire-0").exists())

    def test_prepare_config_bounds_recording_to_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.json"
            destination = root / "config" / "sayall" / "config.json"
            source.write_text(json.dumps({"recording": {"min_ms": 30_000, "max_seconds": 1}}))
            with mock.patch.object(runner, "source_config", return_value=source):
                runner.prepare_config(destination, "verbatim", 7.2)
            recording = json.loads(destination.read_text())["recording"]
            self.assertEqual(recording, {"min_ms": 0, "max_seconds": 13})

    def test_private_writer_never_leaves_report_world_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "report.json"
            output.write_text("old")
            output.chmod(0o644)
            runner.write_private(output, "sensitive transcript")
            self.assertEqual(output.read_text(), "sensitive transcript")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_reference_normalization_rejects_punctuation_only_text(self):
        self.assertEqual(runner.normalize(" … — !!! \n"), "")


if __name__ == "__main__":
    unittest.main()
