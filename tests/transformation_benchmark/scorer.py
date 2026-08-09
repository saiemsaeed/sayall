#!/usr/bin/env python3
"""Deterministic scorer for synthetic SayAll transformation results."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import pathlib
import sys
from collections import Counter, defaultdict

SCORER_VERSION = "1.0.0"
MODES = {"verbatim", "clean", "polished"}
OUTCOMES = {"applied", "safe_fallback", "unsafe_plan", "adapter_error"}


class ContractError(ValueError):
    pass


def read_jsonl(path: pathlib.Path) -> tuple[list[dict], str]:
    raw = path.read_bytes()
    records = []
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeError) as error:
            raise ContractError(f"{path}:{number}: invalid JSON") from error
        if not isinstance(value, dict):
            raise ContractError(f"{path}:{number}: record must be an object")
        records.append(value)
    return records, hashlib.sha256(raw).hexdigest()


def validate_corpus(cases: list[dict]) -> None:
    if not cases:
        raise ContractError("corpus must not be empty")
    ids, identities = set(), set()
    for case in cases:
        required = {"schema_version", "corpus_id", "id", "mode", "category", "input",
                    "expected_output", "expectation", "safety"}
        if not required <= case.keys():
            raise ContractError(f"corpus case missing fields: {case.get('id', '<unknown>')}")
        if type(case["schema_version"]) is not int or case["schema_version"] != 1:
            raise ContractError("unsupported corpus schema version")
        if not isinstance(case["corpus_id"], str) or not case["corpus_id"]:
            raise ContractError("invalid corpus id")
        if not isinstance(case["id"], str) or not case["id"] or case["id"] in ids:
            raise ContractError(f"duplicate or invalid corpus id: {case['id']!r}")
        identities.add((case["schema_version"], case["corpus_id"]))
        ids.add(case["id"])
        if (not isinstance(case["mode"], str) or case["mode"] not in MODES
                or not isinstance(case["expectation"], str)
                or case["expectation"] not in {"preserve", "transform"}):
            raise ContractError(f"invalid mode or expectation: {case['id']}")
        if not all(isinstance(case[field], str) for field in ("category", "input", "expected_output")):
            raise ContractError(f"invalid corpus strings: {case['id']}")
        safety = case["safety"]
        if (not isinstance(safety, dict) or type(safety.get("exact_preservation")) is not bool
                or not isinstance(safety.get("protected_literals"), list)
                or not all(isinstance(item, str) and item for item in safety["protected_literals"])):
            raise ContractError(f"invalid safety contract: {case['id']}")
        alternatives = safety.get("accepted_outputs", [])
        if not isinstance(alternatives, list) or not all(isinstance(item, str) for item in alternatives):
            raise ContractError(f"invalid accepted outputs: {case['id']}")
        if case["expectation"] == "preserve" and case["expected_output"] != case["input"]:
            raise ContractError(f"preserve case changes expected output: {case['id']}")
        if case["expectation"] == "preserve" and not safety["exact_preservation"]:
            raise ContractError(f"preserve case must require exact preservation: {case['id']}")
        if any(literal not in case["expected_output"] for literal in safety["protected_literals"]):
            raise ContractError(f"protected literal missing from expected output: {case['id']}")
        scenario = case.get("scenario")
        if scenario is not None and scenario not in (
            {"type": "inject_plan_failure", "fault": "malformed_plan", "expected_outcome": "safe_fallback"},
            {"type": "inject_plan_failure", "fault": "unsafe_plan", "expected_outcome": "safe_fallback"},
        ):
            raise ContractError(f"invalid fault-injection scenario: {case['id']}")
    if len(identities) != 1:
        raise ContractError("all corpus records must share one schema version and corpus id")


def validate_results(results: list[dict], case_ids: set[str]) -> dict[str, dict]:
    indexed = {}
    for result in results:
        required = {"schema_version", "case_id", "outcome", "output", "latency_ms", "adapter"}
        if not required <= result.keys():
            raise ContractError(f"result missing fields: {result.get('case_id', '<unknown>')}")
        case_id = result["case_id"]
        if not isinstance(case_id, str) or case_id not in case_ids or case_id in indexed:
            raise ContractError(f"unknown or duplicate result case_id: {case_id!r}")
        if (type(result["schema_version"]) is not int or result["schema_version"] != 1
                or not isinstance(result["outcome"], str) or result["outcome"] not in OUTCOMES):
            raise ContractError(f"invalid result schema or outcome: {case_id}")
        if result["output"] is not None and not isinstance(result["output"], str):
            raise ContractError(f"result output must be string or null: {case_id}")
        if result["outcome"] in {"unsafe_plan", "adapter_error"} and result["output"] is not None:
            raise ContractError(f"hard-error outcome must not retain output: {case_id}")
        latency = result["latency_ms"]
        if (not isinstance(latency, (int, float)) or isinstance(latency, bool)
                or not math.isfinite(latency) or latency < 0):
            raise ContractError(f"latency_ms must be finite and non-negative: {case_id}")
        adapter = result["adapter"]
        if (not isinstance(adapter, dict) or not isinstance(adapter.get("name"), str)
                or not isinstance(adapter.get("version"), str)
                or set(adapter) != {"name", "version"}):
            raise ContractError(f"invalid adapter identity: {case_id}")
        plan = result.get("plan")
        validate_plan_evidence(plan, case_id)
        provider = result.get("provider")
        if (provider is not None and
                (not isinstance(provider, dict)
                 or not set(provider) <= {"name", "model"}
                 or any(key in provider and not isinstance(provider[key], str)
                        for key in ("name", "model")))):
            raise ContractError(f"provider identity must contain only string identity fields: {case_id}")
        if result["outcome"] == "safe_fallback" and result.get("fallback_reason") not in {
                "malformed_plan", "unsafe_plan", "provider_error", "adapter_rejection"}:
            raise ContractError(f"safe fallback requires a closed fallback_reason: {case_id}")
        indexed[case_id] = result
    return indexed


def validate_plan_evidence(plan, case_id: str) -> None:
    if plan is None:
        return
    if (not isinstance(plan, dict) or set(plan) != {"schema_version", "operations"}
            or type(plan["schema_version"]) is not int or plan["schema_version"] != 1
            or not isinstance(plan["operations"], list)):
        raise ContractError(f"invalid plan evidence: {case_id}")
    for operation in plan["operations"]:
        if (not isinstance(operation, dict)
                or set(operation) != {"kind", "input_start", "input_end"}
                or not isinstance(operation["kind"], str)
                or operation["kind"] not in {"delete", "replace", "insert", "format"}
                or type(operation["input_start"]) is not int
                or type(operation["input_end"]) is not int
                or operation["input_start"] < 0
                or operation["input_end"] < operation["input_start"]):
            raise ContractError(f"invalid plan operation evidence: {case_id}")


def percentile(values: list[float], percentile_value: int) -> float | int | None:
    """Nearest-rank percentile; deterministic for small benchmark samples."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile_value / 100 * len(ordered)))
    return ordered[rank - 1]


def rate(passed: int, total: int) -> float | None:
    return passed / total if total else None


def score(cases: list[dict], results: list[dict], corpus_sha256: str,
          baseline: dict | None = None) -> dict:
    validate_corpus(cases)
    indexed = validate_results(results, {case["id"] for case in cases})
    scored, category_counts = [], defaultdict(Counter)
    hard_violations = positive_hits = positive_total = negative_hits = negative_total = 0
    latencies = []
    for case in cases:
        result = indexed.get(case["id"])
        violations = []
        output = None if result is None else result["output"]
        outcome = "missing_result" if result is None else result["outcome"]
        if result is None:
            violations.append("missing_result")
        else:
            if case.get("scenario") and outcome != case["scenario"]["expected_outcome"]:
                violations.append("scenario_outcome")
            if (case.get("scenario") and outcome == "safe_fallback"
                    and result.get("fallback_reason") != case["scenario"]["fault"]):
                violations.append("scenario_fallback_reason")
            if outcome in {"unsafe_plan", "adapter_error"}:
                violations.append(outcome)
            elif outcome == "safe_fallback" and output != case["input"]:
                violations.append("fallback_changed_source")
        if output is not None:
            safe_outputs = {case["input"], case["expected_output"],
                            *case["safety"].get("accepted_outputs", [])}
            if outcome == "applied" and output not in safe_outputs:
                violations.append("unsafe_output")
            if case["safety"]["exact_preservation"] and output != case["input"]:
                violations.append("exact_preservation")
            if outcome != "safe_fallback":
                for literal in case["safety"]["protected_literals"]:
                    if literal not in output:
                        violations.append(f"missing_literal:{literal}")
        elif outcome not in {"unsafe_plan", "adapter_error", "missing_result"}:
            violations.append("missing_output")
        safety_pass = not violations
        if case["expectation"] == "transform":
            accepted = {case["expected_output"], *case["safety"].get("accepted_outputs", [])}
            expected_match = output in accepted and outcome == "applied"
        else:
            expected_match = output == case["input"] and outcome in {"applied", "safe_fallback"}
        if case["expectation"] == "transform":
            positive_total += 1
            positive_hits += expected_match
        else:
            negative_total += 1
            negative_hits += output == case["input"] and outcome in {"applied", "safe_fallback"}
        hard_violations += len(violations)
        category_counts[case["category"]]["cases"] += 1
        category_counts[case["category"]]["safety_passes"] += safety_pass
        category_counts[case["category"]]["expected_matches"] += expected_match
        quality_key = "positive" if case["expectation"] == "transform" else "negative"
        category_counts[case["category"]][f"{quality_key}_total"] += 1
        category_counts[case["category"]][f"{quality_key}_passed"] += expected_match
        if result is not None:
            latencies.append(result["latency_ms"])
        scored.append({"case_id": case["id"], "mode": case["mode"],
                       "category": case["category"], "expectation": case["expectation"],
                       "scenario": case.get("scenario"),
                       "source": case["input"], "expected_output": case["expected_output"],
                       "actual_output": output,
                       "outcome": outcome, "safety_pass": safety_pass,
                       "hard_violations": violations, "expected_match": expected_match,
                       "latency_ms": None if result is None else result["latency_ms"],
                       "adapter": None if result is None else {
                           "name": result["adapter"]["name"], "version": result["adapter"]["version"]
                       },
                       "provider": None if result is None else {
                           key: result.get("provider", {}).get(key) for key in ("name", "model")
                           if isinstance(result.get("provider", {}).get(key), str)
                       },
                       "plan": None if result is None else result.get("plan")})
    identity = (cases[0]["schema_version"], cases[0]["corpus_id"])
    summary = {
        "cases": len(cases), "results": len(results), "hard_safety_violations": hard_violations,
        "safety_pass_rate": rate(len(cases) - sum(not item["safety_pass"] for item in scored), len(cases)),
        "negative_preservation": {"passed": negative_hits, "total": negative_total,
                                  "rate": rate(negative_hits, negative_total)},
        "positive_transformations": {"passed": positive_hits, "total": positive_total,
                                     "rate": rate(positive_hits, positive_total)},
        "latency_ms": {f"p{p}": percentile(latencies, p) for p in (50, 95, 99)},
    }
    categories = {name: {"cases": counts["cases"],
                         "safety_pass_rate": rate(counts["safety_passes"], counts["cases"]),
                         "expected_match_rate": rate(counts["expected_matches"], counts["cases"]),
                         "positive_transformations": {
                             "passed": counts["positive_passed"], "total": counts["positive_total"],
                             "rate": rate(counts["positive_passed"], counts["positive_total"])},
                         "negative_preservation": {
                             "passed": counts["negative_passed"], "total": counts["negative_total"],
                             "rate": rate(counts["negative_passed"], counts["negative_total"])}}
                  for name, counts in sorted(category_counts.items())}
    report = {"report_schema_version": 1, "scorer_version": SCORER_VERSION,
              "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "corpus": {"schema_version": identity[0], "id": identity[1],
                         "sha256": corpus_sha256},
              "summary": summary, "categories": categories, "cases": scored}
    report["baseline"] = compare_baseline(report, baseline)
    return report


def compare_baseline(current: dict, baseline: dict | None) -> dict:
    if baseline is None:
        return {"comparable": False, "reasons": ["no baseline supplied"], "deltas": {}}
    if not isinstance(baseline, dict) or not isinstance(baseline.get("corpus"), dict):
        return {"comparable": False, "reasons": ["baseline contract is invalid"], "deltas": {}}
    reasons = []
    for field in ("schema_version", "id", "sha256"):
        if current["corpus"].get(field) != baseline.get("corpus", {}).get(field):
            reasons.append(f"corpus.{field} differs")
    if current["report_schema_version"] != baseline.get("report_schema_version"):
        reasons.append("report_schema_version differs")
    if reasons:
        return {"comparable": False, "reasons": reasons, "deltas": {}}
    if (not valid_baseline_metrics(baseline)
            or not set(current["categories"]) <= set(baseline["categories"])):
        return {"comparable": False, "reasons": ["baseline metrics are invalid"], "deltas": {}}
    now, before = current["summary"], baseline["summary"]
    deltas = {
        "hard_safety_violations": now["hard_safety_violations"] - before["hard_safety_violations"],
        "negative_preservation_rate": now["negative_preservation"]["rate"] - before["negative_preservation"]["rate"],
        "positive_transformation_rate": now["positive_transformations"]["rate"] - before["positive_transformations"]["rate"],
    }
    for key in ("p50", "p95", "p99"):
        current_value, previous_value = now["latency_ms"][key], before["latency_ms"][key]
        deltas[f"latency_{key}_ms"] = (current_value - previous_value
                                        if current_value is not None and previous_value is not None else None)
    category_deltas = {}
    for name, values in current["categories"].items():
        current_rate = values["positive_transformations"]["rate"]
        previous_rate = baseline.get("categories", {}).get(name, {}).get(
            "positive_transformations", {}).get("rate")
        if current_rate is not None:
            category_deltas[name] = (current_rate - previous_rate
                                     if isinstance(previous_rate, (int, float))
                                     and not isinstance(previous_rate, bool) else None)
    deltas["category_positive_transformation_rates"] = category_deltas
    return {"comparable": True, "reasons": [], "deltas": deltas}


def valid_baseline_metrics(baseline: dict) -> bool:
    try:
        summary = baseline["summary"]
        hard = summary["hard_safety_violations"]
        quality_rates = [summary["negative_preservation"]["rate"],
                         summary["positive_transformations"]["rate"]]
        latencies = [summary["latency_ms"][key] for key in ("p50", "p95", "p99")]
        categories = baseline["categories"]
        if (type(hard) is not int or hard < 0
                or not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                           and math.isfinite(value) and 0 <= value <= 1
                           for value in quality_rates)
                or not all(value is None or (isinstance(value, (int, float))
                                              and not isinstance(value, bool)
                                              and math.isfinite(value) and value >= 0)
                           for value in latencies)
                or not isinstance(categories, dict)):
            return False
        for values in categories.values():
            if not isinstance(values, dict) or not isinstance(values.get("positive_transformations"), dict):
                return False
            value = values["positive_transformations"].get("rate")
            if value is not None and (not isinstance(value, (int, float))
                                      or isinstance(value, bool) or not math.isfinite(value)
                                      or not 0 <= value <= 1):
                return False
        return True
    except (KeyError, TypeError, ValueError):
        return False


def markdown_report(report: dict) -> str:
    summary = report["summary"]
    def percent(value):
        return "—" if value is None else f"{value * 100:.2f}%"
    lines = ["# SayAll transformation benchmark", "",
             f"Corpus: `{report['corpus']['id']}` (`{report['corpus']['sha256'][:12]}`)  ",
             f"Scorer: `{report['scorer_version']}`  ",
             f"Cases/results: **{summary['cases']} / {summary['results']}**", "",
             "## Summary", "", "| Metric | Result |", "| --- | ---: |",
             f"| Hard-safety violations | {summary['hard_safety_violations']} |",
             f"| Safety pass rate | {percent(summary['safety_pass_rate'])} |",
             f"| Negative preservation | {summary['negative_preservation']['passed']}/{summary['negative_preservation']['total']} ({percent(summary['negative_preservation']['rate'])}) |",
             f"| Positive transformations | {summary['positive_transformations']['passed']}/{summary['positive_transformations']['total']} ({percent(summary['positive_transformations']['rate'])}) |",
             f"| Latency p50 / p95 / p99 | {summary['latency_ms']['p50']} / {summary['latency_ms']['p95']} / {summary['latency_ms']['p99']} ms |",
             "", "## Categories", "", "| Category | Cases | Safety | Expected match |",
             "| --- | ---: | ---: | ---: |"]
    for name, values in report["categories"].items():
        lines.append(f"| {name} | {values['cases']} | {percent(values['safety_pass_rate'])} | {percent(values['expected_match_rate'])} |")
    lines.extend(["", "## Failures", ""])
    failures = [case for case in report["cases"] if not case["safety_pass"] or not case["expected_match"]]
    if not failures:
        lines.append("None.")
    else:
        lines.extend(["| Case | Outcome | Safety violations | Expected match |", "| --- | --- | --- | --- |"])
        for case in failures:
            violations = ", ".join(case["hard_violations"]) or "none"
            lines.append(f"| {case['case_id']} | {case['outcome']} | {violations} | {case['expected_match']} |")
        lines.extend(["", "Full synthetic source, expected/actual output, provider/model, and plan evidence is retained in the machine JSON report."])
    comparison = report["baseline"]
    lines.extend(["", "## Baseline", ""])
    if comparison["comparable"]:
        lines.extend(["| Delta | Value |", "| --- | ---: |"])
        for key, value in comparison["deltas"].items():
            rendered = json.dumps(value, sort_keys=True) if isinstance(value, dict) else value
            lines.append(f"| {key} | {rendered if rendered is not None else '—'} |")
    else:
        lines.append("Not comparable: " + "; ".join(comparison["reasons"]) + ".")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    here = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=pathlib.Path, default=here / "corpus-v1.jsonl")
    parser.add_argument("--results", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path)
    parser.add_argument("--json", type=pathlib.Path, required=True)
    parser.add_argument("--markdown", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    cases, corpus_sha = read_jsonl(args.corpus)
    results, _ = read_jsonl(args.results)
    baseline = json.loads(args.baseline.read_text()) if args.baseline else None
    report = score(cases, results, corpus_sha, baseline)
    args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    args.markdown.write_text(markdown_report(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
