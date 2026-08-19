#!/usr/bin/env python3
"""Run prerecorded speech through a debug SayAll HUD end to end."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import plistlib
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import wave

try:
    from .scoring import aggregate, score
except ImportError:
    from scoring import aggregate, score


ROOT = pathlib.Path(__file__).resolve().parents[2]
TERMINAL_STATES = {"success", "error", "cancelled"}


def run(command: list[str]) -> None:
    subprocess.run(command, cwd=ROOT, check=True)


def canonical_fixture(source: pathlib.Path, destination: pathlib.Path) -> float:
    with wave.open(str(source), "rb") as audio:
        if (
            audio.getnchannels() != 1
            or audio.getsampwidth() != 2
            or audio.getframerate() != 16_000
            or audio.getcomptype() != "NONE"
        ):
            raise ValueError("fixture must be uncompressed 16 kHz mono 16-bit WAV")
        frames = audio.readframes(audio.getnframes())
        duration = len(frames) / 2 / 16_000
    if not 0.3 <= duration <= 300:
        raise ValueError("fixture duration must be between 0.3 and 300 seconds")
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(frames)
    destination.chmod(0o600)
    return duration


def source_config() -> pathlib.Path:
    base = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
    return base / "sayall" / "config.json"


def prepare_config(destination: pathlib.Path, mode: str) -> None:
    source = source_config()
    document = json.loads(source.read_text()) if source.exists() else {}
    document.setdefault("stt", {})["streaming"] = True
    document.setdefault("processing", {})["mode"] = mode
    output = document.setdefault("output", {})
    output["method"] = "clipboard"
    output["trailing_space"] = False
    metrics = document.setdefault("metrics", {})
    metrics["enabled"] = True
    metrics["history_max_entries"] = max(10, metrics.get("history_max_entries", 1_000))
    destination.parent.mkdir(parents=True, mode=0o700)
    destination.write_text(json.dumps(document, indent=2) + "\n")
    destination.chmod(0o600)


def build_macos(work: pathlib.Path) -> pathlib.Path:
    run(["zig", "build", "process", "-Doptimize=ReleaseFast"])
    run(["swift", "build", "--package-path", "ui/macos", "-c", "debug", "--arch", "arm64"])
    result = subprocess.run(
        ["swift", "build", "--package-path", "ui/macos", "-c", "debug", "--arch", "arm64", "--show-bin-path"],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )
    swift_bin = pathlib.Path(result.stdout.strip())
    app = work / "SayAll-Acoustic-Test.app"
    macos = app / "Contents" / "MacOS"
    helpers = app / "Contents" / "Helpers"
    resources = app / "Contents" / "Resources"
    for directory in (macos, helpers, resources):
        directory.mkdir(parents=True)
    shutil.copy2(swift_bin / "SayAllApp", macos / "SayAll")
    shutil.copy2(ROOT / "zig-out/bin/sayall-process", helpers / "sayall-process")
    with (ROOT / "ui/macos/Info.plist").open("rb") as source:
        information = plistlib.load(source)
    version = (ROOT / "VERSION").read_text().strip()
    information["CFBundleIdentifier"] = "pro.leets.sayall.acoustic-test"
    information["CFBundleShortVersionString"] = version
    information["CFBundleVersion"] = version
    with (app / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(information, output)
    run([
        "codesign", "--force", "--sign", "-", "--entitlements",
        str(ROOT / "ui/macos/SayAll.entitlements"), str(app),
    ])
    return macos / "SayAll"


def build_linux() -> pathlib.Path:
    run(["zig", "build", "process", "-Doptimize=ReleaseFast"])
    run(["cargo", "build", "--locked", "--manifest-path", "ui/linux/Cargo.toml"])
    executable = ROOT / "ui/linux/target/debug/sayall-hud"
    shutil.copy2(ROOT / "zig-out/bin/sayall-process", executable.parent / "sayall-process")
    return executable


def link_linux_session(runtime: pathlib.Path, environment: dict[str, str]) -> None:
    session_runtime = pathlib.Path(
        environment.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    )
    names = ["bus", "pipewire-0", "pipewire-0-manager"]
    wayland = environment.get("WAYLAND_DISPLAY")
    if wayland and "/" not in wayland:
        names.extend((wayland, wayland + ".lock"))
    for name in names:
        source = session_runtime / name
        target = runtime / name
        if source.exists() and not target.exists():
            target.symlink_to(source)
    hyprland = session_runtime / "hypr"
    if hyprland.exists():
        (runtime / "hypr").symlink_to(hyprland, target_is_directory=True)


def exchange(path: pathlib.Path, method: str) -> dict:
    request = json.dumps({"version": 2, "method": method}, separators=(",", ":")).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall(request)
        response = b""
        while not response.endswith(b"\n"):
            chunk = connection.recv(4_096)
            if not chunk:
                raise RuntimeError("SayAll control endpoint closed without a response")
            response += chunk
            if len(response) > 65_536:
                raise RuntimeError("SayAll control response exceeded limit")
    return json.loads(response)


def wait_for_socket(path: pathlib.Path, process: subprocess.Popen, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"SayAll test app exited with status {process.returncode}")
        if path.exists():
            try:
                exchange(path, "status")
                return
            except (OSError, ValueError):
                pass
        time.sleep(0.025)
    raise TimeoutError("SayAll test control endpoint did not become ready")


def wait_for_state(path: pathlib.Path, expected: set[str], timeout: float) -> tuple[dict, float]:
    started = time.monotonic()
    deadline = started + timeout
    latest = None
    while time.monotonic() < deadline:
        latest = exchange(path, "status")
        if latest.get("state") in expected:
            return latest, (time.monotonic() - started) * 1_000
        time.sleep(0.025)
    raise TimeoutError(f"SayAll did not reach {sorted(expected)}; last response: {latest}")


def terminate(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def execute_once(
    executable: pathlib.Path,
    base_environment: dict[str, str],
    control_socket: pathlib.Path,
    transcript_path: pathlib.Path,
    duration: float,
    log_path: pathlib.Path,
    linux: bool,
) -> tuple[str, dict]:
    environment = dict(base_environment)
    environment["SAYALL_TEST_TRANSCRIPT_PATH"] = str(transcript_path)
    pipeline_metrics_path = transcript_path.with_name(transcript_path.stem + "-pipeline.json")
    startup_metrics_path = transcript_path.with_name(transcript_path.stem + "-startup.json")
    if not linux:
        environment["SAYALL_TEST_PIPELINE_METRICS_PATH"] = str(pipeline_metrics_path)
        environment["SAYALL_TEST_STARTUP_METRICS_PATH"] = str(startup_metrics_path)
    arguments = [str(executable), "--autostart"] if linux else [str(executable)]
    with log_path.open("wb") as log:
        process = subprocess.Popen(arguments, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for_socket(control_socket, process)
            overall_started = time.monotonic()
            started = exchange(control_socket, "toggle")
            if not started.get("ok"):
                raise RuntimeError(f"SayAll rejected start: {started}")
            recording, start_to_recording_ms = wait_for_state(
                control_socket, {"recording", "error", "cancelled"}, 10
            )
            if not recording.get("ok") or recording.get("state") != "recording":
                raise RuntimeError(f"SayAll failed while starting: {recording}")
            time.sleep(duration + 0.15)
            stop_started = time.monotonic()
            stopped = exchange(control_socket, "toggle")
            stop_request_ms = (time.monotonic() - stop_started) * 1_000
            if not stopped.get("ok"):
                raise RuntimeError(f"SayAll rejected stop: {stopped}")
            terminal, _ = wait_for_state(control_socket, TERMINAL_STATES, 50)
            stop_to_terminal_ms = (time.monotonic() - stop_started) * 1_000
            total_ms = (time.monotonic() - overall_started) * 1_000
            if terminal.get("state") != "success":
                raise RuntimeError(f"SayAll pipeline failed: {terminal}")
            if not transcript_path.exists():
                raise RuntimeError("SayAll reported success without producing the test transcript")
            transcript = transcript_path.read_text()
            if not linux:
                deadline = time.monotonic() + 1
                while not pipeline_metrics_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
            timing = {
                "start_to_recording_ms": round(start_to_recording_ms, 3),
                "stop_to_terminal_ms": round(stop_to_terminal_ms, 3),
                "total_session_ms": round(total_ms, 3),
                "stop_request_ms": round(stop_request_ms, 3),
            }
            if pipeline_metrics_path.exists():
                samples = json.loads(pipeline_metrics_path.read_text()).get("samples", [])
                if samples:
                    timing["pipeline"] = samples[-1]
            if startup_metrics_path.exists():
                samples = json.loads(startup_metrics_path.read_text()).get("samples", [])
                if samples:
                    timing["startup"] = samples[-1]
            return transcript, timing
        finally:
            terminate(process)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--reference", required=True, type=pathlib.Path)
    parser.add_argument("--mode", choices=("verbatim", "clean", "polished"), default="verbatim")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max-wer", type=float, default=0.35)
    parser.add_argument("--max-cer", type=float, default=0.20)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if not 1 <= args.runs <= 20:
        parser.error("--runs must be between 1 and 20")
    if args.max_wer < 0 or args.max_cer < 0:
        parser.error("quality thresholds must not be negative")
    fixture = args.fixture.resolve(strict=True)
    reference_path = args.reference.resolve(strict=True)
    reference = reference_path.read_text().strip()
    if not reference:
        parser.error("reference transcript is empty")

    platform = "macos" if sys.platform == "darwin" else "linux" if sys.platform.startswith("linux") else None
    if platform is None:
        parser.error("the acoustic HUD runner supports macOS and Linux")
    work_parent = pathlib.Path("/tmp")
    work = pathlib.Path(tempfile.mkdtemp(prefix="sayall-acoustic-e2e-", dir=work_parent))
    work.chmod(0o700)
    output = args.output or ROOT / "dist/acoustic-e2e" / f"{platform}-{int(time.time())}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        canonical = work / "fixture.wav"
        duration = canonical_fixture(fixture, canonical)
        config_home = work / "config"
        prepare_config(config_home / "sayall/config.json", args.mode)
        runtime = work / "runtime"
        runtime.mkdir(mode=0o700)
        control_socket = runtime / "control.sock"
        environment = dict(os.environ)
        if platform == "linux":
            link_linux_session(runtime, environment)
        environment.update({
            "XDG_CONFIG_HOME": str(config_home),
            "XDG_RUNTIME_DIR": str(runtime),
            "SAYALL_SOCKET": str(control_socket),
            "SAYALL_TEST_AUDIO_FIXTURE": str(canonical),
        })
        if platform == "macos":
            environment["SAYALL_TEST_RECORDING_ROOT"] = str(work / "recordings")
            executable = build_macos(work)
        else:
            executable = build_linux()
        if not executable.is_file():
            raise FileNotFoundError(f"test executable does not exist: {executable}")

        results = []
        for index in range(1, args.runs + 1):
            transcript_path = work / f"transcript-{index}.txt"
            transcript, timing = execute_once(
                executable, environment, control_socket, transcript_path, duration,
                work / f"sayall-{index}.log", platform == "linux",
            )
            measured = score(reference, transcript)
            results.append({"run": index, "transcript": transcript, **measured, **timing})
            print(
                f"run {index}: word accuracy {measured['word_accuracy_percent']:.2f}%, "
                f"character accuracy {measured['character_accuracy_percent']:.2f}%, "
                f"stop latency {timing['stop_to_terminal_ms']:.1f} ms"
            )
        corpus = aggregate(results)
        stop_latencies = [result["stop_to_terminal_ms"] for result in results]
        report = {
            "schema_version": 1,
            "platform": platform,
            "fixture": fixture.name,
            "fixture_duration_seconds": duration,
            "processing_mode": args.mode,
            "runs": results,
            "aggregate": {
                **corpus,
                "median_stop_to_terminal_ms": statistics.median(stop_latencies),
                "mean_stop_to_terminal_ms": statistics.mean(stop_latencies),
            },
            "thresholds": {"max_wer": args.max_wer, "max_cer": args.max_cer},
        }
        report["passed"] = corpus["wer"] <= args.max_wer and corpus["cer"] <= args.max_cer
        output.write_text(json.dumps(report, indent=2) + "\n")
        output.chmod(0o600)
        print(f"aggregate word accuracy: {corpus['word_accuracy_percent']:.2f}% (WER {corpus['wer']:.4f})")
        print(f"aggregate character accuracy: {corpus['character_accuracy_percent']:.2f}% (CER {corpus['cer']:.4f})")
        print(f"report: {output}")
        return 0 if report["passed"] else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
