#!/usr/bin/env python3
"""Privacy-safe live benchmark for the shipped sayall-process worker."""
from __future__ import annotations

import argparse, datetime, hashlib, json, math, os, pathlib, selectors
import struct, subprocess, sys, tempfile, time, unicodedata, wave

HARNESS_VERSION = "1.1.0"
MAX_FRAME_BYTES = 1024 * 1024
ERROR_CODES = {"invalid_request", "incompatible_version", "invalid_audio", "audio_too_short",
               "audio_too_long", "missing_deepgram_key", "deepgram_unauthorized",
               "deepgram_rate_limited", "deepgram_server", "deepgram_network",
               "response_too_large", "internal"}

class ProtocolError(RuntimeError): pass

def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    text = "".join(" " if unicodedata.category(c).startswith(("P", "Z")) else c for c in text)
    return " ".join(text.split())

def edit_distance(a, b) -> int:
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        nxt = [i]
        for j, y in enumerate(b, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j-1] + (x != y)))
        row = nxt
    return row[-1]

def error_counts(reference: str, hypothesis: str) -> dict:
    r, h = normalize(reference), normalize(hypothesis)
    rw, hw = r.split(), h.split()
    return {"word_edits": edit_distance(rw, hw), "reference_words": len(rw),
            "char_edits": edit_distance(list(r.replace(" ", "")), list(h.replace(" ", ""))),
            "reference_chars": len(r.replace(" ", ""))}

def aggregate(counts: list[dict]) -> dict:
    out = {k: sum(x[k] for x in counts) for k in ("word_edits", "reference_words", "char_edits", "reference_chars")}
    out["wer"] = out["word_edits"] / out["reference_words"] if out["reference_words"] else None
    out["cer"] = out["char_edits"] / out["reference_chars"] if out["reference_chars"] else None
    return out

def classify(expect_no_speech: bool, result: dict) -> str:
    if result.get("harness_error"): return "harness_error"
    status, text = result.get("status"), normalize(result.get("text") or "")
    if status == "error": return "provider_error"
    if expect_no_speech:
        if status == "no_speech": return "expected_no_speech"
        return "false_speech" if status == "success" and text else "invalid_result"
    return "speech_ok" if status == "success" and text else "missing_speech"

def thresholds_pass(clips: list[dict], corpus: dict, max_wer=None, max_cer=None) -> bool:
    if any(c["classification"] not in ("speech_ok", "expected_no_speech") for c in clips): return False
    if any(c.get("mode") == "stream" and c.get("effective_transport") != "stream" for c in clips): return False
    if max_wer is not None and (corpus["wer"] is None or corpus["wer"] > max_wer): return False
    if max_cer is not None and (corpus["cer"] is None or corpus["cer"] > max_cer): return False
    return True

def make_audio(clip: dict, directory: pathlib.Path) -> tuple[pathlib.Path, bytes]:
    pcm_path, wav_path = directory/(clip["id"] + ".pcm"), directory/(clip["id"] + ".wav")
    source = clip["source"]
    if source["type"] == "silence":
        pcm = b"\0\0" * int(16000 * source["duration_seconds"])
    elif source["type"] == "noise":
        # Deterministic low-amplitude pseudo-noise without external libraries.
        state, samples = 1, []
        for _ in range(int(16000 * source["duration_seconds"])):
            state = (1103515245 * state + 12345) & 0x7fffffff
            samples.append(((state >> 16) % 101) - 50)
        pcm = struct.pack("<%dh" % len(samples), *samples)
    elif source["type"] == "espeak-ng":
        raw = directory/(clip["id"] + "-raw.wav")
        subprocess.run(["espeak-ng", "-v", source["voice"], "-w", str(raw), source["text"]], check=True, timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.chmod(raw, 0o600)
        subprocess.run(["sox", str(raw), "-r", "16000", "-c", "1", "-b", "16", "-e", "signed-integer", str(wav_path)],
                       check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        raw.unlink()
        with wave.open(str(wav_path), "rb") as w: pcm = w.readframes(w.getnframes())
    else: raise ValueError("unsupported source type: " + source["type"])
    pcm_path.write_bytes(pcm); os.chmod(pcm_path, 0o600)
    if not wav_path.exists():
        with wave.open(str(wav_path), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(pcm)
    os.chmod(wav_path, 0o600)
    return wav_path, pcm

def source_metadata(clip: dict) -> dict:
    source = clip["source"]
    metadata = {"type": source["type"]}
    for field in ("voice", "duration_seconds"):
        if field in source: metadata[field] = source[field]
    metadata["recipe_sha256"] = hashlib.sha256(
        json.dumps(source, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return metadata

def request(clip, wav_path, pcm_path, key, args):
    return {"version": 3, "wav_path": str(wav_path), "pcm_path": str(pcm_path),
            "deepgram_api_key": key, "deepgram_model": args.model, "deepgram_language": clip["language"],
            "deepgram_region": args.region, "deepgram_keyterms": [], "stream_finalize_timeout_ms": 5000,
            "llm_api_key": "", "processing_profile": "verbatim"}

def read_line(proc, timeout):
    deadline, frame = time.monotonic() + timeout, bytearray()
    descriptor = proc.stdout.fileno(); os.set_blocking(descriptor, False)
    with selectors.DefaultSelector() as sel:
        sel.register(descriptor, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not sel.select(remaining): raise TimeoutError("worker output timed out")
            chunk = os.read(descriptor, min(4096, MAX_FRAME_BYTES + 1 - len(frame)))
            if not chunk: raise ProtocolError("worker exited before protocol frame")
            frame.extend(chunk)
            if len(frame) > MAX_FRAME_BYTES: raise ProtocolError("worker protocol frame too large")
            newline = frame.find(b"\n")
            if newline >= 0:
                try: return json.loads(frame[:newline])
                except (json.JSONDecodeError, UnicodeError) as error: raise ProtocolError("invalid worker JSON") from error

def validate_ready(frame):
    if (not isinstance(frame, dict) or frame.get("version") != 3 or frame.get("event") != "ready"
            or not isinstance(frame.get("streaming"), bool)):
        raise ProtocolError("invalid worker ready frame")

def validate_result(frame):
    if not isinstance(frame, dict): raise ProtocolError("worker result is not an object")
    status = frame.get("status")
    if frame.get("version") != 3 or status not in ("success", "no_speech", "error"):
        raise ProtocolError("invalid worker result frame")
    if frame.get("processing_profile") not in ("verbatim", "clean", "polished", "legacy_v1"):
        raise ProtocolError("worker result omitted effective processing profile")
    if frame.get("transport") not in ("rest", "stream"):
        raise ProtocolError("worker result omitted authoritative transport")
    text, error = frame.get("text"), frame.get("error")
    if status == "success" and (not isinstance(text, str) or not text or error is not None):
        raise ProtocolError("successful worker result violated its field contract")
    if status == "no_speech" and (text is not None or error is not None):
        raise ProtocolError("no-speech worker result violated its field contract")
    if status == "error" and (text is not None or not isinstance(error, str) or error not in ERROR_CODES):
        raise ProtocolError("worker error result violated its field contract")

def error_category(error):
    if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
        return "timeout"
    if isinstance(error, (ProtocolError, json.JSONDecodeError, UnicodeError)):
        return "protocol"
    if isinstance(error, (BrokenPipeError, ConnectionError)):
        return "process"
    return "worker"

def run_worker(worker, mode, req, pcm, timeout):
    started = time.monotonic()
    audio_duration_ms = round(len(pcm) / 32)
    if mode == "rest":
        req.pop("pcm_path"); req.pop("stream_finalize_timeout_ms")
        proc = subprocess.run([str(worker)], input=json.dumps(req).encode(), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env={}, timeout=timeout, check=False)
        if proc.returncode: raise RuntimeError("worker failed without a result")
        result, active = json.loads(proc.stdout), None
        validate_result(result)
        terminal_validated = time.monotonic()
        timing = {"elapsed_ms": round((terminal_validated-started)*1000),
                  "audio_duration_ms": audio_duration_ms,
                  "request_to_result_ms": round((terminal_validated-started)*1000),
                  "stream_ready_ms": None, "audio_feed_ms": None, "post_stop_ms": None}
    else:
        pcm_path = pathlib.Path(req["pcm_path"]); pcm_path.write_bytes(b""); os.chmod(pcm_path, 0o600)
        proc = subprocess.Popen([str(worker), "--stream"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env={})
        try:
            proc.stdin.write(json.dumps(req).encode()+b"\n"); proc.stdin.flush()
            ready = read_line(proc, min(timeout, 15)); validate_ready(ready); active = ready["streaming"]
            ready_received = time.monotonic()
            # 100 ms chunks approximate capture cadence while Deepgram tails the growing file.
            feed_started = time.monotonic()
            with pcm_path.open("ab", buffering=0) as out:
                for offset in range(0, len(pcm), 3200): out.write(pcm[offset:offset+3200]); time.sleep(0.1)
            feed_finished = time.monotonic()
            proc.stdin.write(b'{"version":3,"command":"finish","force_rest":false}\n'); proc.stdin.flush()
            finish_sent = time.monotonic()
            result = read_line(proc, timeout)
            validate_result(result)
            terminal_validated = time.monotonic()
            if proc.wait(timeout=5) != 0: raise RuntimeError("worker exited unsuccessfully")
            completed = time.monotonic()
            timing = {"elapsed_ms": round((completed-started)*1000),
                      "audio_duration_ms": audio_duration_ms, "request_to_result_ms": None,
                      "stream_ready_ms": round((ready_received-started)*1000),
                      "audio_feed_ms": round((feed_finished-feed_started)*1000),
                      "post_stop_ms": round((terminal_validated-finish_sent)*1000)}
        except BaseException:
            proc.kill(); proc.wait(); raise
        finally:
            for pipe in (proc.stdin, proc.stdout):
                try: pipe.close()
                except OSError: pass
    return result, active, timing

def worker_identity(worker):
    p = subprocess.run([str(worker), "--worker-info"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       env={}, timeout=10, check=True)
    try: frame = json.loads(p.stdout)
    except (json.JSONDecodeError, UnicodeError) as error: raise ProtocolError("invalid worker identity JSON") from error
    if (not isinstance(frame, dict) or type(frame.get("protocol_version")) is not int
            or frame["protocol_version"] != 3
            or not isinstance(frame.get("build_version"), str)
            or not frame["build_version"] or len(frame["build_version"]) > 128
            or any(character.isspace() for character in frame["build_version"])):
        raise ProtocolError("invalid worker identity frame")
    return {"protocol_version": frame["protocol_version"], "build_version": frame["build_version"]}

def positive_finite(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number

def nonnegative_finite(value):
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("must be finite and non-negative")
    return number

def failure_clip(clip, mode, metadata, category):
    counts = error_counts(clip["expected_transcript"], "")
    return {"id": clip["id"], "language": clip["language"], "mode": mode,
            "expect_no_speech": clip["expect_no_speech"], "classification": "harness_error",
            "worker_status": None, "worker_error": None, "streaming_active": None,
            "harness_error": category, "effective_transport": None, "elapsed_ms": None,
            "audio_duration_ms": None, "request_to_result_ms": None, "stream_ready_ms": None,
            "audio_feed_ms": None, "post_stop_ms": None,
            "audio_sha256": None, **metadata, **counts,
            "wer": counts["word_edits"]/counts["reference_words"] if counts["reference_words"] else None,
            "cer": counts["char_edits"]/counts["reference_chars"] if counts["reference_chars"] else None}

def main(argv=None):
    here = pathlib.Path(__file__).resolve().parent
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", type=pathlib.Path, default=here/"manifest-v1.json")
    p.add_argument("--worker", type=pathlib.Path, default=pathlib.Path("zig-out/bin/sayall-process"))
    p.add_argument("--output", type=pathlib.Path, default=pathlib.Path("deepgram-benchmark.json"))
    p.add_argument("--mode", choices=("rest", "stream", "both"), default="both")
    p.add_argument("--model", default="nova-3"); p.add_argument("--region", choices=("global", "eu", "au"), default="global")
    p.add_argument("--secret-env", default="SAYALL_DEEPGRAM_BENCHMARK_API_KEY")
    p.add_argument("--timeout", type=positive_finite, default=60)
    p.add_argument("--max-wer", type=nonnegative_finite); p.add_argument("--max-cer", type=nonnegative_finite)
    p.add_argument("--enforce", action="store_true"); p.add_argument("--dry-run", action="store_true")
    args = p.parse_args(argv)
    raw = args.manifest.read_bytes(); manifest = json.loads(raw)
    for c in manifest["clips"]:
        for field in ("id", "source", "expected_transcript", "language", "expect_no_speech", "provenance", "license", "sha256"):
            if field not in c: raise ValueError(f"clip missing {field}")
    modes = ("rest", "stream") if args.mode == "both" else (args.mode,)
    key = os.environ.get(args.secret_env, "")
    report = {"harness_version": HARNESS_VERSION, "manifest_schema_version": manifest["schema_version"],
              "manifest_sha256": hashlib.sha256(raw).hexdigest(), "corpus_id": manifest["corpus_id"],
              "synthetic_canary": True, "date_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "execution": "dry_run" if args.dry_run else "live",
              "model": args.model, "region": args.region, "modes": list(modes),
              "worker_build": None, "harness_error": None, "clips": []}
    try:
        if not args.dry_run and not key:
            report["harness_error"] = "missing_secret"
        elif not args.dry_run:
            try:
                report["worker_build"] = worker_identity(args.worker)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError):
                report["harness_error"] = "worker_identity"
        with tempfile.TemporaryDirectory(prefix="sayall-deepgram-") as td:
            for clip in manifest["clips"]:
                metadata = {"source": source_metadata(clip), "provenance": clip["provenance"],
                            "license": clip["license"], "declared_audio_sha256": clip["sha256"]}
                if args.dry_run:
                    for mode in modes:
                        report["clips"].append({"id": clip["id"], "language": clip["language"],
                            "mode": mode, "expect_no_speech": clip["expect_no_speech"], **metadata})
                    continue
                if report["harness_error"]:
                    for mode in modes: report["clips"].append(failure_clip(clip, mode, metadata, report["harness_error"]))
                    continue
                try:
                    wav_path, pcm = make_audio(clip, pathlib.Path(td))
                    digest = hashlib.sha256(wav_path.read_bytes()).hexdigest()
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, wave.Error):
                    for mode in modes: report["clips"].append(failure_clip(clip, mode, metadata, "audio_generation"))
                    continue
                for mode in modes:
                    operation_started = time.monotonic()
                    try:
                        result, active, timing = run_worker(
                            args.worker.resolve(), mode,
                            request(clip, wav_path, pathlib.Path(td)/(clip["id"]+"-grow.pcm"), key, args),
                            pcm, args.timeout,
                        )
                    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError, json.JSONDecodeError) as error:
                        result = {"status": "error", "harness_error": error_category(error)}
                        active = None
                        timing = {"elapsed_ms": round((time.monotonic()-operation_started)*1000),
                                  "audio_duration_ms": round(len(pcm) / 32),
                                  "request_to_result_ms": None, "stream_ready_ms": None,
                                  "audio_feed_ms": None, "post_stop_ms": None}
                    counts = error_counts(clip["expected_transcript"], result.get("text") or "")
                    transport = result.get("transport")
                    report["clips"].append({"id": clip["id"], "language": clip["language"], "mode": mode,
                        "expect_no_speech": clip["expect_no_speech"], "classification": classify(clip["expect_no_speech"], result),
                        "worker_status": result.get("status"),
                        "worker_error": result.get("error") if result.get("status") == "error" else None,
                        "streaming_active": active,
                        "harness_error": result.get("harness_error"), "effective_transport": transport,
                        **timing, "audio_sha256": digest, **metadata, **counts,
                        "wer": counts["word_edits"]/counts["reference_words"] if counts["reference_words"] else None,
                        "cer": counts["char_edits"]/counts["reference_chars"] if counts["reference_chars"] else None})
    finally:
        speech_counts = [{k: c[k] for k in ("word_edits","reference_words","char_edits","reference_chars")}
                         for c in report["clips"] if "word_edits" in c and not c["expect_no_speech"]]
        report["corpus"] = aggregate(speech_counts)
        expected_count = len(manifest["clips"]) * len(modes)
        passed = (not report["harness_error"] and len(report["clips"]) == expected_count
                  and thresholds_pass(report["clips"], report["corpus"], args.max_wer, args.max_cer)) if not args.dry_run else None
        report["thresholds"] = {"enforced": args.enforce and not args.dry_run,
                                "max_wer": args.max_wer, "max_cer": args.max_cer, "passed": passed}
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+"\n")
    if args.dry_run: return 0
    if report["harness_error"] == "missing_secret": return 1
    return 1 if args.enforce and not report["thresholds"]["passed"] else 0

if __name__ == "__main__": sys.exit(main())
