import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/transformation-benchmark.yml").read_text()
RELEASE = (ROOT / ".github/workflows/release.yml").read_text()


class WorkflowTests(unittest.TestCase):
    def test_ci_has_no_live_provider_or_groq_secret_access(self):
        self.assertNotIn("live_provider", WORKFLOW + RELEASE)
        self.assertNotIn("GROQ_API_KEY", WORKFLOW + RELEASE)
        self.assertIn("--no-live-provider", WORKFLOW)

    def test_manual_and_release_runs_bind_to_exact_deterministic_source(self):
        self.assertIn('test "$actual_sha" = "$BENCHMARK_SHA"', WORKFLOW)
        self.assertIn('echo "ADAPTER_VERSION=$actual_sha"', WORKFLOW)
        self.assertIn('--adapter-version "$ADAPTER_VERSION"', WORKFLOW)
        transformation = RELEASE.split("  transformation-integration:\n", 1)[1].split("\n  linux-assets:", 1)[0]
        self.assertIn("benchmark_sha: ${{ github.sha }}", transformation)


if __name__ == "__main__":
    unittest.main()
