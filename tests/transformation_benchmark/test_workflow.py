import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/transformation-benchmark.yml").read_text()
RELEASE = (ROOT / ".github/workflows/release.yml").read_text()


class WorkflowTests(unittest.TestCase):
    def test_manual_dispatch_has_no_live_provider_input_or_unconditional_secret(self):
        manual = WORKFLOW.split("  workflow_dispatch:\n", 1)[1].split("\nconcurrency:", 1)[0]
        self.assertNotIn("live_provider", manual)
        self.assertNotIn("GROQ_API_KEY", manual)
        self.assertNotIn("GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}", WORKFLOW)

    def test_release_only_secret_and_exact_source(self):
        self.assertIn("inputs.live_provider && github.event_name == 'push'", WORKFLOW)
        self.assertIn("startsWith(github.ref, 'refs/heads/release/')", WORKFLOW)
        self.assertIn('test "$actual_sha" = "$BENCHMARK_SHA"', WORKFLOW)
        self.assertIn('echo "ADAPTER_VERSION=$actual_sha"', WORKFLOW)
        self.assertIn('--adapter-version "$ADAPTER_VERSION"', WORKFLOW)
        transformation = RELEASE.split("  transformation-integration:\n", 1)[1].split("\n  linux-assets:", 1)[0]
        self.assertIn("live_provider: true", transformation)


if __name__ == "__main__":
    unittest.main()
