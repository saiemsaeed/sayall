import json
import pathlib
import tempfile
import unittest

from scorer import ContractError, main, markdown_report, percentile, read_jsonl, score


HERE = pathlib.Path(__file__).resolve().parent
CORPUS = HERE / "corpus-v1.jsonl"
DEFAULT_OUTPUT = object()


def load_cases():
    return read_jsonl(CORPUS)


def result(case, latency=10, output=DEFAULT_OUTPUT, outcome="applied", fallback_reason=None):
    record = {
        "schema_version": 1,
        "case_id": case["id"],
        "outcome": outcome,
        "output": case["expected_output"] if output is DEFAULT_OUTPUT else output,
        "latency_ms": latency,
        "adapter": {"name": "unit-fixture", "version": "1"},
        "provider": {"name": "none", "model": "deterministic-fixture"},
        "plan": None,
    }
    if fallback_reason:
        record["fallback_reason"] = fallback_reason
    return record


def perfect_report(latencies=None):
    cases, digest = load_cases()
    latencies = latencies or [index + 1 for index in range(len(cases))]
    results = []
    for case, latency in zip(cases, latencies):
        if case.get("scenario"):
            results.append(result(case, latency, case["input"], "safe_fallback",
                                  case["scenario"]["fault"]))
        else:
            results.append(result(case, latency))
    return cases, results, score(cases, results, digest)


class ScoringTests(unittest.TestCase):
    def test_reference_outputs_have_zero_hard_safety_violations(self):
        cases, results, report = perfect_report()
        self.assertEqual(report["summary"]["hard_safety_violations"], 0)
        self.assertEqual(report["summary"]["safety_pass_rate"], 1.0)
        self.assertEqual(report["summary"]["cases"], len(cases))
        self.assertEqual(report["summary"]["results"], len(results))
        self.assertTrue(report["qualification"]["adapter_integrity"])
        self.assertTrue(report["qualification"]["passed"])
        self.assertFalse(report["qualification"]["quality_thresholds_ratified"])

    def test_negative_preservation_is_exact(self):
        cases, digest = load_cases()
        results = [result(case) for case in cases]
        target = next(item for item in cases if item["id"] == "clean-negative-repetition")
        results[cases.index(target)] = result(target, output="It was very cold.")
        report = score(cases, results, digest)
        negative = report["summary"]["negative_preservation"]
        self.assertEqual(negative["passed"], negative["total"] - 1)
        scored = next(item for item in report["cases"] if item["case_id"] == target["id"])
        self.assertIn("exact_preservation", scored["hard_violations"])

    def test_positive_transformations_and_category_rates(self):
        cases, digest = load_cases()
        results = [result(case) for case in cases]
        target = next(item for item in cases if item["id"] == "clean-filler-um")
        results[cases.index(target)] = result(target, output=target["input"])
        report = score(cases, results, digest)
        positive = report["summary"]["positive_transformations"]
        self.assertEqual(positive["passed"], positive["total"] - 1)
        self.assertEqual(report["categories"]["fillers"]["cases"], 2)
        self.assertEqual(report["categories"]["fillers"]["expected_match_rate"], 0.5)
        self.assertEqual(report["categories"]["fillers"]["safety_pass_rate"], 1.0)
        self.assertEqual(report["categories"]["fillers"]["positive_transformations"]["rate"], 0.5)
        self.assertIsNone(report["categories"]["fillers"]["negative_preservation"]["rate"])

    def test_unallowlisted_fact_or_value_change_is_hard_failure(self):
        cases, digest = load_cases()
        results = [result(case) for case in cases]
        values = next(case for case in cases if case["id"] == "polished-values")
        punctuation = next(case for case in cases if case["id"] == "polished-punctuation")
        results[cases.index(values)] = result(
            values, output="Budget: $9,999, not $2,100. Delivery: June 6, 2031. Distance: 14.2 kilometers."
        )
        results[cases.index(punctuation)] = result(
            punctuation, output=punctuation["expected_output"] + " The release is approved."
        )
        report = score(cases, results, digest)
        for case_id in (values["id"], punctuation["id"]):
            scored = next(item for item in report["cases"] if item["case_id"] == case_id)
            self.assertIn("unsafe_output", scored["hard_violations"])
            self.assertIsNone(scored["actual_output"])

    def test_safe_fallback_is_safety_pass_and_positive_miss(self):
        cases, digest = load_cases()
        results = [result(case) for case in cases]
        targets = [case for case in cases if case["category"] == "plan_safety"]
        reasons = ["malformed_plan", "unsafe_plan"]
        for target, reason in zip(targets, reasons):
            results[cases.index(target)] = result(
                target, output=target["input"], outcome="safe_fallback", fallback_reason=reason
            )
        report = score(cases, results, digest)
        self.assertEqual(report["summary"]["hard_safety_violations"], 0)
        self.assertEqual(report["categories"]["plan_safety"]["safety_pass_rate"], 1.0)
        self.assertEqual(report["categories"]["plan_safety"]["expected_match_rate"], 0.0)
        self.assertEqual(
            report["summary"]["positive_transformations"]["passed"],
            report["summary"]["positive_transformations"]["total"] - 2,
        )
        swapped = list(results)
        target = targets[0]
        swapped[cases.index(target)] = result(
            target, output=target["input"], outcome="safe_fallback",
            fallback_reason="unsafe_plan"
        )
        swapped_report = score(cases, swapped, digest)
        swapped_case = next(item for item in swapped_report["cases"] if item["case_id"] == target["id"])
        self.assertIn("scenario_fallback_reason", swapped_case["hard_violations"])

    def test_safe_fallback_preserves_source_and_negative_quality(self):
        cases, results, baseline = perfect_report()
        preserve = next(case for case in cases if case["id"] == "clean-negative-repetition")
        results[cases.index(preserve)] = result(
            preserve, output=preserve["input"], outcome="safe_fallback",
            fallback_reason="provider_error"
        )
        report = score(cases, results, baseline["corpus"]["sha256"])
        scored = next(item for item in report["cases"] if item["case_id"] == preserve["id"])
        self.assertTrue(scored["safety_pass"])
        self.assertTrue(scored["expected_match"])
        self.assertEqual(report["summary"]["negative_preservation"]["rate"], 1.0)
        self.assertNotIn(f"| {preserve['id']} |", markdown_report(report))

        list_case = next(case for case in cases if case["id"] == "polished-list")
        results[cases.index(list_case)] = result(
            list_case, output=list_case["input"], outcome="safe_fallback",
            fallback_reason="adapter_rejection"
        )
        list_report = score(cases, results, baseline["corpus"]["sha256"])
        list_scored = next(item for item in list_report["cases"] if item["case_id"] == list_case["id"])
        self.assertTrue(list_scored["safety_pass"])

    def test_unsafe_plan_outcome_is_a_hard_failure(self):
        cases, digest = load_cases()
        results = [result(case) for case in cases]
        target = next(case for case in cases if case["id"] == "clean-unsafe-plan-fallback")
        results[cases.index(target)] = result(target, output=None, outcome="unsafe_plan")
        report = score(cases, results, digest)
        scored = next(item for item in report["cases"] if item["case_id"] == target["id"])
        self.assertFalse(scored["safety_pass"])
        self.assertIn("unsafe_plan", scored["hard_violations"])

    def test_baseline_comparison_reports_quality_and_latency_deltas(self):
        cases, _ = load_cases()
        cases, results, baseline = perfect_report([10] * len(cases))
        current_results = [dict(item, latency_ms=20) for item in results]
        target = next(case for case in cases if case["id"] == "clean-filler-um")
        current_results[cases.index(target)] = result(target, latency=20, output=target["input"])
        current = score(cases, current_results, baseline["corpus"]["sha256"], baseline)
        comparison = current["baseline"]
        self.assertTrue(comparison["comparable"])
        self.assertLess(comparison["deltas"]["positive_transformation_rate"], 0)
        self.assertEqual(comparison["deltas"]["latency_p95_ms"], 10)
        self.assertLess(
            comparison["deltas"]["category_positive_transformation_rates"]["fillers"], 0
        )
        incompatible = json.loads(json.dumps(baseline))
        incompatible["corpus"]["sha256"] = "different"
        self.assertFalse(score(cases, results, baseline["corpus"]["sha256"], incompatible)["baseline"]["comparable"])

    def test_latency_percentiles_use_nearest_rank(self):
        self.assertEqual(percentile([1, 2, 3, 4, 100], 50), 3)
        self.assertEqual(percentile([1, 2, 3, 4, 100], 95), 100)
        self.assertEqual(percentile([1, 2, 3, 4, 100], 99), 100)
        self.assertIsNone(percentile([], 95))

    def test_cli_generates_machine_json_and_markdown_reports(self):
        cases, results, _ = perfect_report()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            result_path = root / "results.jsonl"
            result_path.write_text("".join(json.dumps(item) + "\n" for item in results))
            json_path, markdown_path = root / "report.json", root / "report.md"
            self.assertEqual(main(["--results", str(result_path), "--json", str(json_path),
                                   "--markdown", str(markdown_path)]), 0)
            machine = json.loads(json_path.read_text())
            markdown = markdown_path.read_text()
        self.assertEqual(machine["summary"]["cases"], len(cases))
        evidence = next(item for item in machine["cases"] if item["case_id"] == "clean-filler-um")
        self.assertEqual(evidence["provider"], {"name": "none", "model": "deterministic-fixture"})
        self.assertIn("source", evidence)
        self.assertIn("expected_output", evidence)
        self.assertIn("actual_output", evidence)
        self.assertIn("plan", evidence)
        self.assertIn("# SayAll transformation benchmark", markdown)
        self.assertIn("Hard-safety violations", markdown)
        self.assertEqual(markdown, markdown_report(machine))

    def test_contract_rejects_duplicate_results_and_invalid_fallback(self):
        cases, digest = load_cases()
        duplicate = result(cases[0])
        with self.assertRaises(ContractError):
            score(cases, [duplicate, duplicate], digest)
        invalid = result(cases[0], output=cases[0]["input"], outcome="safe_fallback")
        with self.assertRaises(ContractError):
            score(cases, [invalid], digest)

    def test_contract_rejects_unsafe_evidence_and_malformed_types(self):
        cases, digest = load_cases()
        for field, value in (
            ("adapter", {"name": "fixture", "version": "1", "token": "secret"}),
            ("provider", {"name": "none", "model": "fixture", "headers": "secret"}),
            ("plan", {"schema_version": 1, "operations": [], "raw_response": "secret"}),
        ):
            invalid = result(cases[0])
            invalid[field] = value
            with self.assertRaises(ContractError):
                score(cases, [invalid], digest)
        retained_error = result(cases[0], output="provider body", outcome="adapter_error")
        with self.assertRaises(ContractError):
            score(cases, [retained_error], digest)
        malformed_plan = result(cases[0])
        malformed_plan["plan"] = {"schema_version": 1, "operations": [
            {"kind": [], "input_start": 0, "input_end": 1}
        ]}
        with self.assertRaises(ContractError):
            score(cases, [malformed_plan], digest)
        invalid_case = dict(cases[0], mode=[])
        with self.assertRaises(ContractError):
            score([invalid_case], [], digest)
        unknown_case = dict(cases[0], raw_provider_body="secret")
        with self.assertRaises(ContractError):
            score([unknown_case], [], digest)
        unknown_safety = dict(cases[0], safety={**cases[0]["safety"], "api_key": "secret"})
        with self.assertRaises(ContractError):
            score([unknown_safety], [], digest)
        gated = next(case for case in cases if case["id"] == "clean-filler-um")
        wrong_gate = dict(gated, mode="polished")
        with self.assertRaises(ContractError):
            score([wrong_gate], [], digest)
        invalid_result = result(cases[0])
        invalid_result["schema_version"] = True
        with self.assertRaises(ContractError):
            score(cases, [invalid_result], digest)
        unknown_result = result(cases[0])
        unknown_result["raw_provider_body"] = "secret"
        with self.assertRaises(ContractError):
            score(cases, [unknown_result], digest)
        stray_reason = result(cases[0])
        stray_reason["fallback_reason"] = "provider_error"
        with self.assertRaises(ContractError):
            score(cases, [stray_reason], digest)

    def test_enforced_cli_fails_a_deterministic_transformation_miss(self):
        cases, results, _ = perfect_report()
        target = next(case for case in cases if case["id"] == "clean-filler-um")
        results[cases.index(target)] = result(target, output=target["input"])
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            result_path = root / "results.jsonl"
            result_path.write_text("".join(json.dumps(item) + "\n" for item in results))
            self.assertEqual(main(["--enforce-hard", "--results", str(result_path),
                                   "--json", str(root / "report.json"),
                                   "--markdown", str(root / "report.md")]), 1)
            report = json.loads((root / "report.json").read_text())
        self.assertFalse(report["qualification"]["deterministic_transformations"])
        self.assertFalse(report["qualification"]["passed"])

    def test_malformed_compatible_baseline_is_not_compared(self):
        cases, results, baseline = perfect_report()
        malformed = {"report_schema_version": 1, "corpus": baseline["corpus"],
                     "summary": {}, "categories": {}}
        report = score(cases, results, baseline["corpus"]["sha256"], malformed)
        self.assertFalse(report["baseline"]["comparable"])
        self.assertEqual(report["baseline"]["reasons"], ["baseline metrics are invalid"])
        malformed["summary"] = baseline["summary"]
        malformed["categories"] = {"fillers": []}
        report = score(cases, results, baseline["corpus"]["sha256"], malformed)
        self.assertFalse(report["baseline"]["comparable"])


if __name__ == "__main__":
    unittest.main()
