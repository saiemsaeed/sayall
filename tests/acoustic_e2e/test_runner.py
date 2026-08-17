import pathlib
import tempfile
import unittest
import wave

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


if __name__ == "__main__":
    unittest.main()
