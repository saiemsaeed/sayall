import json
import pathlib
import subprocess
import unittest
from unittest import mock

from adapter import parse_runner_response, positive_finite, positive_integer, run_case, runner_request
from scorer import ContractError


CASE = {
    "id": "synthetic",
    "mode": "polished",
    "input": "Synthetic input",
    "expected_output": "Synthetic output",
    "safety": {"accepted_outputs": []},
    "scenario": {"fault": "malformed_plan"},
}


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

    def test_case_timeout_becomes_content_free_adapter_error(self):
        expired = subprocess.TimeoutExpired("runner", 1, output=b"provider body", stderr=b"private")
        with mock.patch("adapter.subprocess.run", side_effect=expired):
            result = run_case(CASE, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["outcome"], "adapter_error")
        self.assertIsNone(result["output"])
        self.assertNotIn("fallback_reason", result)
        self.assertNotIn("private-key", json.dumps(result))
        self.assertNotIn("provider body", json.dumps(result))

    def test_runner_fault_fallback_is_projected_without_extra_fields(self):
        response = {"schema_version": 1, "outcome": "safe_fallback", "output": "Synthetic input",
                    "fallback_reason": "malformed_plan"}
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response).encode())
        with mock.patch("adapter.subprocess.run", return_value=completed):
            result = run_case(CASE, pathlib.Path("runner"), "private-key", "model", "version", 1)
        self.assertEqual(result["fallback_reason"], "malformed_plan")
        self.assertEqual(result["output"], CASE["input"])
        self.assertEqual(set(result["provider"]), {"name", "model"})
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

    def test_limits_reject_nonpositive_and_nonfinite_values(self):
        for value in ("0", "-1", "nan", "inf"):
            with self.assertRaises(Exception):
                positive_finite(value)
        for value in ("0", "-1"):
            with self.assertRaises(Exception):
                positive_integer(value)


if __name__ == "__main__":
    unittest.main()
