import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from adapter import main, parse_runner_response, positive_finite, positive_integer, run_case, runner_request
from scorer import ContractError


CASE = {
    "id": "synthetic",
    "mode": "polished",
    "input": "Synthetic input",
    "expected_output": "Synthetic output",
    "safety": {"accepted_outputs": []},
    "scenario": {"fault": "malformed_plan"},
}
POLISHED_CASE = {key: value for key, value in CASE.items() if key != "scenario"}


class AdapterTests(unittest.TestCase):
    def test_request_passes_only_synthetic_case_and_required_provider_inputs(self):
        request = runner_request(CASE, "private-key", "model")
        self.assertEqual(set(request), {"schema_version", "mode", "input", "groq_api_key", "model", "fault"})
        self.assertEqual(request["groq_api_key"], "private-key")
        clean = runner_request(dict(CASE, mode="clean"), "private-key", "model")
        self.assertEqual(clean["groq_api_key"], "")

    def test_runner_response_is_closed_and_never_accepts_raw_provider_data(self):
        valid = {"schema_version": 1, "outcome": "applied", "output": "Synthetic output",
                 "fallback_reason": None}
        self.assertEqual(parse_runner_response(json.dumps(valid).encode()), valid)
        for field in ("raw_provider_body", "headers", "api_key"):
            with self.assertRaises(ContractError):
                parse_runner_response(json.dumps({**valid, field: "private"}).encode())
        with self.assertRaises(ContractError):
            parse_runner_response(b"not json")

    def test_fault_injection_timeout_becomes_content_free_adapter_error(self):
        expired = subprocess.TimeoutExpired("runner", 1, output=b"provider body", stderr=b"private")
        with mock.patch("adapter.subprocess.run", side_effect=expired):
            result = run_case(CASE, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["outcome"], "adapter_error")
        self.assertIsNone(result["output"])
        self.assertNotIn("fallback_reason", result)
        self.assertNotIn("private-key", json.dumps(result))
        self.assertNotIn("provider body", json.dumps(result))

    def test_polished_timeout_is_content_free_adapter_error(self):
        expired = subprocess.TimeoutExpired("runner", 1, output=b"provider body", stderr=b"private")
        with mock.patch("adapter.subprocess.run", side_effect=expired):
            result = run_case(POLISHED_CASE, pathlib.Path("runner"), "private-key",
                              "model", "version", 1)
        self.assertEqual(result["outcome"], "adapter_error")
        self.assertIsNone(result["output"])
        self.assertNotIn("fallback_reason", result)
        self.assertNotIn("provider body", json.dumps(result))
        self.assertEqual(result["provider"]["invocation_mode"], "live_attempted")

    def test_no_credential_skips_polished_runner(self):
        with mock.patch("adapter.subprocess.run") as subprocess_run:
            result = run_case(POLISHED_CASE, pathlib.Path("runner"), "", "model", "version", 1)
        subprocess_run.assert_not_called()
        self.assertEqual(result["outcome"], "safe_fallback")
        self.assertEqual(result["fallback_reason"], "missing_credential")
        self.assertEqual(result["provider"]["invocation_mode"], "not_attempted_no_credential")

    def test_no_live_provider_ignores_local_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "results.jsonl"
            with (mock.patch.dict(os.environ, {"GROQ_API_KEY": "private-key"}),
                  mock.patch("adapter.run", return_value=[]) as adapter_run,
                  mock.patch("adapter.validate_results")):
                self.assertEqual(main(["--no-live-provider", "--output", str(output)]), 0)
        self.assertEqual(adapter_run.call_args.args[2], "")

    def test_deterministic_timeouts_are_hard_adapter_errors(self):
        expired = subprocess.TimeoutExpired("runner", 1)
        for mode in ("verbatim", "clean"):
            deterministic = {**POLISHED_CASE, "mode": mode}
            with self.subTest(mode=mode), mock.patch("adapter.subprocess.run", side_effect=expired):
                result = run_case(deterministic, pathlib.Path("runner"), "", "model", "version", 1)
                self.assertEqual(result["outcome"], "adapter_error")
                self.assertIsNone(result["output"])
                self.assertEqual(result["provider"]["invocation_mode"], "not_applicable")

    def test_runner_fault_fallback_is_projected_without_extra_fields(self):
        response = {"schema_version": 1, "outcome": "safe_fallback", "output": "Synthetic input",
                    "fallback_reason": "malformed_plan"}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(CASE, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["fallback_reason"], "malformed_plan")
        self.assertEqual(result["output"], CASE["input"])
        self.assertEqual(set(result["provider"]), {"name", "model", "invocation_mode"})
        self.assertIsNone(result["plan"])

    def test_unallowlisted_runner_output_is_never_persisted(self):
        private = "raw provider body private-key"
        response = {"schema_version": 1, "outcome": "applied", "output": private,
                    "fallback_reason": None}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(CASE, pathlib.Path("runner"), "private-key", "model", "version", 1)
        serialized = json.dumps(result)
        self.assertEqual(result["outcome"], "unsafe_plan")
        self.assertIsNone(result["output"])
        self.assertNotIn(private, serialized)

    def test_polished_nonexact_formatting_variant_is_retained(self):
        response = {"schema_version": 1, "outcome": "applied", "output": "Synthetic, input!",
                    "fallback_reason": None}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(POLISHED_CASE, pathlib.Path("runner"), "private-key",
                              "model", "version", 1)
        self.assertEqual(result["outcome"], "applied")
        self.assertEqual(result["output"], "Synthetic, input!")

    def test_production_numbered_list_marker_and_spoken_ordinal_are_retained(self):
        case = {
            **POLISHED_CASE,
            "input": "First validate second run",
            "expected_output": "1. Validate\n2. Run",
        }
        production_output = "1. First validate\n2. second run"
        response = {"schema_version": 1, "outcome": "applied", "output": production_output,
                    "fallback_reason": None}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(case, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["outcome"], "applied")
        self.assertEqual(result["output"], production_output)

    def test_introduced_numeric_sign_is_rejected_before_persistence(self):
        case = {**POLISHED_CASE, "input": "Distance 14.2 kilometers"}
        response = {"schema_version": 1, "outcome": "applied",
                    "output": "Distance -14.2 kilometers", "fallback_reason": None}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(case, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["outcome"], "unsafe_plan")
        self.assertIsNone(result["output"])

    def test_lost_operator_is_rejected_before_persistence(self):
        case = {**POLISHED_CASE, "input": "Compute 6 / 3"}
        response = {"schema_version": 1, "outcome": "applied", "output": "Compute 6 3",
                    "fallback_reason": None}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(case, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["outcome"], "unsafe_plan")
        self.assertIsNone(result["output"])

    def test_limits_reject_nonpositive_and_nonfinite_values(self):
        for value in ("0", "-1", "nan", "inf"):
            with self.assertRaises(Exception):
                positive_finite(value)
        for value in ("0", "-1"):
            with self.assertRaises(Exception):
                positive_integer(value)


if __name__ == "__main__":
    unittest.main()
