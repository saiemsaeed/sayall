#!/usr/bin/env python3
"""Run the synthetic corpus through SayAll's production transformation APIs."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import pathlib
import subprocess
import sys
import time

from scorer import (ContractError, polished_semantic_invariant, read_jsonl,
                    validate_corpus, validate_results)

ADAPTER_NAME = "sayall-production-transformation"
ADAPTER_SCHEMA_VERSION = 1
DEFAULT_MODEL = "openai/gpt-oss-20b"
RUNNER_FIELDS = {"schema_version", "outcome", "output", "fallback_reason"}


def positive_finite(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number


def positive_integer(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def runner_request(case: dict, api_key: str, model: str) -> dict:
    return {
        "schema_version": ADAPTER_SCHEMA_VERSION,
        "mode": case["mode"],
        "input": case["input"],
        "groq_api_key": api_key if case["mode"] == "polished" else "",
        "model": model,
        "fault": (case.get("scenario") or {}).get("fault"),
    }


def parse_runner_response(raw: bytes) -> dict:
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ContractError("case runner returned invalid JSON") from error
    if (not isinstance(value, dict) or set(value) != RUNNER_FIELDS
            or value.get("schema_version") != ADAPTER_SCHEMA_VERSION
            or value.get("outcome") not in {"applied", "safe_fallback", "adapter_error"}
            or (value.get("output") is not None and not isinstance(value["output"], str))
            or (value.get("fallback_reason") is not None
                and value["fallback_reason"] not in {"malformed_plan", "unsafe_plan", "provider_error",
                                                     "adapter_rejection", "missing_credential"})):
        raise ContractError("case runner violated its closed response contract")
    if value["outcome"] == "safe_fallback" and value["fallback_reason"] is None:
        raise ContractError("case runner fallback omitted its reason")
    if value["outcome"] != "safe_fallback" and value["fallback_reason"] is not None:
        raise ContractError("case runner retained a fallback reason on a non-fallback")
    return value


def run_case(case: dict, runner: pathlib.Path, api_key: str, model: str,
             adapter_version: str, timeout: float) -> dict:
    started = time.monotonic()
    invocation_mode = ("not_applicable" if case["mode"] != "polished" else
                       "live_attempted" if api_key else "not_attempted_no_credential")
    if case["mode"] == "polished" and not api_key and not case.get("scenario"):
        response = {"outcome": "safe_fallback", "output": case["input"],
                    "fallback_reason": "missing_credential"}
    else:
        try:
            completed = subprocess.run(
                [str(runner)],
                input=json.dumps(runner_request(case, api_key, model), separators=(",", ":")).encode(),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env={},
                timeout=timeout,
                check=False,
            )
            if completed.returncode:
                raise ContractError("case runner exited unsuccessfully")
            response = parse_runner_response(completed.stdout)
        except (OSError, subprocess.SubprocessError, ContractError):
            response = {"outcome": "adapter_error", "output": None, "fallback_reason": None}
    safe_outputs = {case["input"], case["expected_output"],
                    *case["safety"].get("accepted_outputs", [])}
    applied_is_unsafe = (response["outcome"] == "applied" and
                         (not isinstance(response["output"], str) or
                          (case["mode"] == "polished"
                           and not polished_semantic_invariant(case["input"], response["output"])) or
                          (case["mode"] != "polished" and response["output"] not in safe_outputs)))
    unsafe_output = (applied_is_unsafe
                     or (response["outcome"] == "safe_fallback"
                         and response["output"] != case["input"])
                     or (response["outcome"] == "adapter_error" and response["output"] is not None))
    if unsafe_output:
        response = {"outcome": "unsafe_plan", "output": None, "fallback_reason": None}
    result = {
        "schema_version": ADAPTER_SCHEMA_VERSION,
        "case_id": case["id"],
        "outcome": response["outcome"],
        "output": response["output"],
        "latency_ms": round((time.monotonic() - started) * 1000, 3),
        "adapter": {"name": ADAPTER_NAME, "version": adapter_version},
        "provider": ({"name": "groq", "model": model, "invocation_mode": invocation_mode}
                     if case["mode"] == "polished" else
                     {"name": "none", "model": "production-deterministic",
                      "invocation_mode": invocation_mode}),
        "plan": None,
    }
    if response["outcome"] == "safe_fallback":
        result["fallback_reason"] = response["fallback_reason"]
    return result


def run(cases: list[dict], runner: pathlib.Path, api_key: str, model: str,
        adapter_version: str, timeout: float, concurrency: int) -> list[dict]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(run_case, case, runner, api_key, model,
                                   adapter_version, timeout) for case in cases]
        return [future.result() for future in futures]


def main(argv=None) -> int:
    here = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=pathlib.Path, default=here / "corpus-v1.jsonl")
    parser.add_argument("--runner", type=pathlib.Path,
                        default=pathlib.Path("zig-out/bin/sayall-transformation-benchmark-case"))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--secret-env", default="GROQ_API_KEY")
    parser.add_argument("--no-live-provider", action="store_true")
    parser.add_argument("--adapter-version", default=os.environ.get("GITHUB_SHA", "dev"))
    parser.add_argument("--timeout", type=positive_finite, default=45.0)
    parser.add_argument("--concurrency", type=positive_integer, default=1)
    args = parser.parse_args(argv)

    cases, _ = read_jsonl(args.corpus)
    validate_corpus(cases)
    api_key = "" if args.no_live_provider else os.environ.get(args.secret_env, "")
    results = run(cases, args.runner.resolve(), api_key, args.model,
                  args.adapter_version, args.timeout, args.concurrency)
    validate_results(results, {case["id"]: case for case in cases})
    args.output.write_text("".join(json.dumps(result, sort_keys=True) + "\n" for result in results))
    polished = sum(case["mode"] == "polished" for case in cases)
    print(f"wrote {len(results)} synthetic results; polished live cases scheduled: {polished if api_key else 0}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
