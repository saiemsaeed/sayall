#!/usr/bin/env python3
"""Render privacy-safe current-versus-previous benchmark and HUD evidence."""
from __future__ import annotations

import argparse, base64, html, json, pathlib, statistics

METRICS = [("Combined provider canary WER", "wer", True),
           ("REST provider canary WER", "rest_wer", True),
           ("Streaming provider canary WER", "stream_wer", True),
           ("Combined provider canary CER", "cer", True),
           ("REST speech request → result", "rest_ms", False),
           ("Stream speech connection ready", "stream_ready_ms", False),
           ("Stream speech audio duration", "audio_duration_ms", False),
           ("Paced speech audio feed", "audio_feed_ms", False),
           ("Stream speech finish → final transcript", "post_stop_ms", False),
           ("Stream speech total including paced audio", "stream_total_ms", False)]
ACCEPTED = ("speech_ok", "expected_no_speech")
IDENTITY_FIELDS = ("model", "region", "corpus_id", "manifest_schema_version", "manifest_sha256")

def median(values):
    clean = [value for value in values if isinstance(value, (int, float))]
    return round(statistics.median(clean)) if clean else None

def mode_wer(clips):
    counted = [clip for clip in clips if isinstance(clip.get("word_edits"), int) and isinstance(clip.get("reference_words"), int)]
    words = sum(clip["reference_words"] for clip in counted)
    if words:
        return sum(clip["word_edits"] for clip in counted) / words
    values = [clip["wer"] for clip in clips if isinstance(clip.get("wer"), (int, float))]
    return sum(values) / len(values) if values else None

def summarize(report):
    clips = report.get("clips", [])
    rest = [c for c in clips if c.get("mode") == "rest" and c.get("effective_transport") == "rest" and c.get("classification") in ACCEPTED and not c.get("expect_no_speech", False)]
    stream = [c for c in clips if c.get("mode") == "stream" and c.get("effective_transport") == "stream" and c.get("classification") in ACCEPTED and not c.get("expect_no_speech", False)]
    return {
        "wer": report.get("corpus", {}).get("wer"),
        "rest_wer": mode_wer(rest),
        "stream_wer": mode_wer(stream),
        "cer": report.get("corpus", {}).get("cer"),
        "rest_ms": median(c.get("request_to_result_ms", c.get("elapsed_ms")) for c in rest),
        "stream_ready_ms": median(c.get("stream_ready_ms") for c in stream if c.get("streaming_active") is True),
        "audio_duration_ms": median(c.get("audio_duration_ms") for c in stream),
        "audio_feed_ms": median(c.get("audio_feed_ms") for c in stream),
        "post_stop_ms": median(c.get("post_stop_ms") for c in stream),
        "stream_total_ms": median(c.get("elapsed_ms") for c in stream),
        "failures": sum(c.get("classification") not in ACCEPTED for c in clips),
    }

def compatibility(current, previous):
    if not previous: return False, ["No previous retained report is available"]
    reasons = []
    if current.get("execution") != "live" or previous.get("execution") != "live":
        reasons.append("both reports must be live executions")
    if current.get("harness_error") or previous.get("harness_error"):
        reasons.append("a report-level harness failure is present")
    for field in IDENTITY_FIELDS:
        if current.get(field) != previous.get(field): reasons.append(f"{field} differs")
    if sorted(current.get("modes", [])) != sorted(previous.get("modes", [])): reasons.append("requested modes differ")
    return not reasons, reasons

def metadata(report):
    worker = report.get("worker_build") or {}
    return {"Date": report.get("date_utc") or "—", "Execution": report.get("execution") or "—",
            "Harness": report.get("harness_version") or "—", "Worker": worker.get("build_version") or "—",
            "Model / region": f"{report.get('model') or '—'} / {report.get('region') or '—'}",
            "Corpus": report.get("corpus_id") or "—",
            "Repetitions per clip/transport": report.get("runs_per_case", 1),
            "Scope": report.get("corpus_description") or "Provider canary; inspect the versioned manifest for coverage",
            "Manifest": (report.get("manifest_sha256") or "—")[:12],
            "Thresholds": str((report.get("thresholds") or {}).get("passed", "—")),
            "Harness error": report.get("harness_error") or "none"}

def value(value, percent=False):
    if value is None: return "—"
    return f"{value * 100:.2f}%" if percent else f"{value:.0f} ms"

def change(current, previous, percent=False):
    if current is None or previous is None: return "—"
    difference = current - previous
    unit = " pp" if percent else " ms"
    rendered = difference * 100 if percent else difference
    if abs(rendered) < 0.005: return "no change"
    return f"{rendered:+.2f}{unit} {'worse' if difference > 0 else 'better'}"

def links(args):
    items = []
    for label, url in (("Current benchmark run", args.current_run_url),
                       ("Previous benchmark run", args.previous_run_url),
                       ("HUD screenshot CI run", args.ui_run_url)):
        if url: items.append(f"[{label}]({url})")
    return " · ".join(items)

def markdown_report(current, previous, args):
    now, before = summarize(current), summarize(previous) if previous else {}
    comparable, reasons = compatibility(current, previous)
    current_metadata, previous_metadata = metadata(current), metadata(previous or {})
    lines = ["# SayAll external-dependency benchmark and HUD evidence", "", links(args), "",
             "> WER/CER measure the frozen provider canary corpus, not microphone capture or all real-world dictation. Lower is better. Streaming total includes real-time audio playback; finish → final transcript is the user-visible post-stop latency.", "",
             "## Run identity", "", "| Field | Current | Previous |", "| --- | --- | --- |"]
    for key in current_metadata:
        lines.append(f"| {key} | {current_metadata[key]} | {previous_metadata[key]} |")
    if not comparable:
        lines.extend(["", f"> **No metric delta is calculated:** {'; '.join(reasons)}."])
    lines.extend(["", "## Current versus previous", "", "| Metric | Current | Previous | Change |", "| --- | ---: | ---: | --- |"])
    for label, key, percent in METRICS:
        delta = change(now.get(key), before.get(key), percent) if comparable else "not comparable"
        lines.append(f"| {label} | {value(now.get(key), percent)} | {value(before.get(key), percent)} | {delta} |")
    lines.extend(["", f"Failures: **{now['failures']}** current / **{before.get('failures', '—')}** previous.", "",
                  "## Per-clip evidence", "",
                  "| Clip | Run | Mode | Classification | Transport | Total | Audio | Feed | REST result | Stream ready | Post-stop | WER |", "| --- | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"])
    for clip in current.get("clips", []):
        lines.append("| {id} | {run} | {mode} | {classification} | {transport} | {total} | {audio} | {feed} | {rest} | {ready} | {post} | {wer} |".format(
            id=clip.get("id", "—"), run=clip.get("run", 1), mode=clip.get("mode", "—"), classification=clip.get("classification", "—"),
            transport=clip.get("effective_transport") or "—", total=value(clip.get("elapsed_ms")),
            audio=value(clip.get("audio_duration_ms")), feed=value(clip.get("audio_feed_ms")),
            rest=value(clip.get("request_to_result_ms")), ready=value(clip.get("stream_ready_ms")),
            post=value(clip.get("post_stop_ms")), wer=value(clip.get("wer"), True)))
    lines.extend(["", "## HUD screenshots", "",
                  "Download the run artifact and open `benchmark-report.html` to view the macOS and Linux HUD states beside these statistics.", ""])
    return "\n".join(lines)

def html_report(current, previous, args, screenshot_dir):
    now, before = summarize(current), summarize(previous) if previous else {}
    comparable, reasons = compatibility(current, previous)
    current_metadata, previous_metadata = metadata(current), metadata(previous or {})
    metric_rows = "".join(
        f"<tr><td>{html.escape(label)}</td><td>{value(now.get(key), percent)}</td>"
        f"<td>{value(before.get(key), percent)}</td><td>{html.escape(change(now.get(key), before.get(key), percent) if comparable else 'not comparable')}</td></tr>"
        for label, key, percent in METRICS
    )
    metadata_rows = "".join(f"<tr><td>{html.escape(key)}</td><td>{html.escape(str(current_metadata[key]))}</td><td>{html.escape(str(previous_metadata[key]))}</td></tr>" for key in current_metadata)
    warning = "" if comparable else f'<p class="warning"><strong>No metric delta is calculated:</strong> {html.escape("; ".join(reasons))}.</p>'
    clip_rows = "".join(
        "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
            *(html.escape(str(item)) for item in (
                clip.get("id", "—"), clip.get("run", 1), clip.get("mode", "—"), clip.get("classification", "—"),
                clip.get("effective_transport") or "—", value(clip.get("elapsed_ms")),
                value(clip.get("audio_duration_ms")), value(clip.get("audio_feed_ms")),
                value(clip.get("request_to_result_ms")), value(clip.get("stream_ready_ms")),
                value(clip.get("post_stop_ms")), value(clip.get("wer"), True))))
        for clip in current.get("clips", [])
    )
    images = []
    if screenshot_dir and screenshot_dir.exists():
        for path in sorted(screenshot_dir.rglob("*.png")):
            encoded = base64.b64encode(path.read_bytes()).decode()
            label = str(path.relative_to(screenshot_dir)).replace("/", " · ")
            images.append(f'<figure><img src="data:image/png;base64,{encoded}" alt="{html.escape(label)}"><figcaption>{html.escape(label)}</figcaption></figure>')
    link_html = " · ".join(
        f'<a href="{html.escape(url, quote=True)}">{html.escape(label)}</a>'
        for label, url in (("Current benchmark run", args.current_run_url),
                           ("Previous benchmark run", args.previous_run_url),
                           ("HUD screenshot CI run", args.ui_run_url)) if url)
    return f"""<!doctype html><meta charset="utf-8"><title>SayAll benchmark report</title>
<style>body{{font:15px system-ui;margin:32px;max-width:1200px;color:#17202a}}table{{border-collapse:collapse;width:100%;margin:18px 0 32px}}th,td{{border:1px solid #d8dee4;padding:9px;text-align:left}}th{{background:#f6f8fa}}.note{{background:#eef6ff;padding:14px;border-radius:8px}}.warning{{background:#fff3cd;padding:14px;border-radius:8px}}.shots{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:18px}}figure{{margin:0;padding:16px;border:1px solid #d8dee4;border-radius:10px}}img{{max-width:100%;image-rendering:auto}}figcaption{{margin-top:10px;font-weight:600}}</style>
<h1>SayAll external-dependency benchmark and HUD evidence</h1><p>{link_html}</p><p class="note">WER/CER measure the frozen provider canary corpus, not microphone capture or all real-world dictation. Lower is better. Streaming total includes real-time audio playback; finish → final transcript is the user-visible post-stop latency.</p>
<h2>Run identity</h2><table><thead><tr><th>Field</th><th>Current</th><th>Previous</th></tr></thead><tbody>{metadata_rows}</tbody></table>{warning}
<h2>Current versus previous</h2><table><thead><tr><th>Metric</th><th>Current</th><th>Previous</th><th>Change</th></tr></thead><tbody>{metric_rows}</tbody></table>
<p>Failures: <strong>{now['failures']}</strong> current / <strong>{before.get('failures', '—')}</strong> previous.</p>
<h2>Per-clip evidence</h2><table><thead><tr><th>Clip</th><th>Run</th><th>Mode</th><th>Classification</th><th>Transport</th><th>Total</th><th>Audio</th><th>Feed</th><th>REST result</th><th>Stream ready</th><th>Post-stop</th><th>WER</th></tr></thead><tbody>{clip_rows}</tbody></table>
<h2>Rendered HUD states</h2><div class="shots">{''.join(images) or '<p>No matching CI screenshot artifact was available.</p>'}</div>"""

def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", type=pathlib.Path, required=True)
    parser.add_argument("--previous", type=pathlib.Path)
    parser.add_argument("--hud-dir", type=pathlib.Path)
    parser.add_argument("--markdown", type=pathlib.Path, required=True)
    parser.add_argument("--html", type=pathlib.Path, required=True)
    parser.add_argument("--current-run-url", default="")
    parser.add_argument("--previous-run-url", default="")
    parser.add_argument("--ui-run-url", default="")
    args = parser.parse_args(argv)
    def load(path):
        try: return json.loads(path.read_text()) if path and path.is_file() else None
        except (OSError, json.JSONDecodeError, UnicodeError): return None
    current = load(args.current) or {
        "execution":"not_run", "harness_error":"benchmark_not_run", "clips":[], "corpus":{},
        "thresholds":{"passed":None}, "modes":[], "date_utc":"—", "harness_version":"—"}
    previous = load(args.previous)
    markdown = markdown_report(current, previous, args)
    args.markdown.write_text(markdown + "\n")
    args.html.write_text(html_report(current, previous, args, args.hud_dir))
    return 0

if __name__ == "__main__": raise SystemExit(main())
