# Production transformation benchmark

This directory contains a privacy-safe, synthetic benchmark for Feature Set A
text modes. The versioned corpus and scorer remain independent contracts;
`adapter.py` and the test-only Zig case runner connect them to the production
`groq.clean` and `groq.polished` APIs without introducing a second
transformation implementation.

## Corpus contract (`corpus-v1.jsonl`)

Each non-empty line is one JSON object. All records share `schema_version: 1`
and one `corpus_id`.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable unique case ID. |
| `mode` | enum | `verbatim`, `clean`, or `polished`. |
| `category` | string | Aggregation bucket. |
| `input` | string | Entirely synthetic source text. |
| `expected_output` | string | One deterministic reference output. |
| `expectation` | enum | `preserve` (negative control) or `transform` (positive case). |
| `safety.exact_preservation` | boolean | Any output change is a hard violation. |
| `safety.protected_literals` | string[] | Case-sensitive literals that must survive any output. |
| `safety.accepted_outputs` | string[] | Optional additional exact safe/reference variants. |
| `scenario` | object | Optional benchmark-owned deterministic fault injection. |

The corpus covers exact Verbatim preservation; positive and negative Clean
fillers, repetition, false starts, and explicit backtracks; Polished
punctuation, paragraphs, and lists; inert questions/instructions; quoted cue
words; URLs, email addresses, and paths; negation, quantities, dates,
currencies, and measurements; and malformed/unsafe plan fallback scenarios.
Synthetic reserved-domain addresses are used and no audio, user transcript, or
credential is present.

## Adapter result contract (JSONL)

The production adapter writes one object per attempted corpus case:

```json
{"schema_version":1,"case_id":"clean-filler-um","outcome":"applied","output":"please send the synthetic report.","latency_ms":18.4,"adapter":{"name":"sayall-production-transformation","version":"dev"},"provider":{"name":"none","model":"production-deterministic"},"plan":null}
```

Required fields are `schema_version`, `case_id`, `outcome`, `output`,
`latency_ms`, and `adapter` (`name` and `version`). `provider` and `plan` are
optional privacy-safe evidence objects. Adapter and provider identity objects
are closed, and reports project only adapter `name`/`version` and provider
`name`/`model`. The benchmark-owned plan evidence contract is deliberately not
the production schema: it contains `schema_version: 1` and an `operations`
array whose closed records contain `kind` (`delete`, `replace`, `insert`, or
`format`) and integer `input_start`/`input_end`. Replacement text is omitted;
the separately allowlisted actual output supplies the result evidence. Unknown
evidence fields are rejected so credentials, raw provider bodies, and headers
cannot flow into reports. `unsafe_plan` and `adapter_error` outcomes require a
null output.

The top-level result object is closed to the documented required fields plus
`fallback_reason`, `provider`, and `plan`; unknown fields are rejected.
`outcome` is one of:

- `applied`: `output` is the accepted transformed text.
- `safe_fallback`: validation/provider handling returned the original source;
  `fallback_reason` is required and is `malformed_plan`, `unsafe_plan`,
  `provider_error`, or `adapter_rejection`.
- `unsafe_plan`: an unsafe plan escaped the adapter boundary; hard failure.
- `adapter_error`: no safety-assured output; hard failure.

A safe fallback must equal the source exactly. It passes safety, but a positive
case is still a transformation miss. Missing/duplicate/unknown result IDs and
malformed contract fields are rejected rather than silently scored.

Plan-safety cases declare `scenario.type: inject_plan_failure`, a fault of
`malformed_plan` or `unsafe_plan`, and `expected_outcome: safe_fallback`. The
adapter invokes the real mode API first, then injects the named failure at its
boundary without relying on a provider to emit a particular malformed
response. This remains deterministic when no live key is available. Returning
anything except a source-exact fallback is a hard scenario failure.

## Production adapter

Build and run locally:

```sh
zig build transformation-benchmark-case -Doptimize=ReleaseSafe
python3 tests/transformation_benchmark/adapter.py \
  --adapter-version "$(git rev-parse HEAD)" \
  --output transformation-results.jsonl
python3 tests/transformation_benchmark/scorer.py --enforce-hard \
  --results transformation-results.jsonl \
  --json transformation-report.json \
  --markdown transformation-report.md
```

Set `GROQ_API_KEY` to exercise Polished live. Every Polished corpus case invokes
exactly one `groq.polished` call. Verbatim and Clean always use their production
deterministic paths and never receive the key. The adapter defaults to four
case processes and a 45-second per-case deadline; `--concurrency` and
`--timeout` may lower or raise those explicit bounds.

The process supervisor discards stderr and accepts only a closed response from
the case runner. It emits provider name/model, adapter name/version, synthetic
source-derived output, latency, and optional benchmark-owned evidence. The
production API does not expose its validated plan, so `plan` is null rather
than copying or reparsing a raw provider body. Credentials, headers, provider
bodies, and error text are never written to results or reports.

## Scoring and reports

Run with any contract-compatible result file:

```sh
python3 tests/transformation_benchmark/scorer.py \
  --results /path/to/results.jsonl \
  --json transformation-report.json \
  --markdown transformation-report.md
```

Add `--baseline previous-report.json` to calculate deltas. Baselines are
comparable only when corpus schema, ID, SHA-256, and report schema match.
Latency p50/p95/p99 use the deterministic nearest-rank definition. The machine
JSON includes category rates and per-case synthetic source, reference, actual
output, provider/model, adapter, and edit-plan evidence. Markdown summarizes the
same report and lists all safety failures and expected-output misses.

## Workflow and release qualification

`transformation-benchmark.yml` is manually dispatchable against any selected
ref and reusable by the release workflow. A release passes its exact
`github.sha`, so checkout, adapter identity, tests, and evidence all bind to the
release source. The workflow runs unit tests, downloads the newest retained
compatible report when available, runs the adapter, renders JSON and Markdown,
and uploads result JSONL plus both reports for 30 days. A missing live Groq
secret produces source-exact Polished fallbacks while deterministic coverage
still runs; add the `GROQ_API_KEY` repository secret for live Polished evidence.

The initially enforced release policy is deliberately narrower than the
proposed quality policy:

- valid, complete closed adapter results;
- zero hard-safety violations across all cases;
- exactly 100% negative preservation; and
- exact accepted output for the deterministic Clean transformation gates
  (`clean-filler-um` and `clean-url-path`).

Polished uses exactly the live production source-anchored API when a secret is
available, but provider quality and latency vary and have not been ratified.
Positive quality, category rates, latency, and compatible-baseline deltas are
therefore artifact evidence only and do not block a release. The JSON report
records `quality_thresholds_ratified: false`, and Markdown states the same
policy. This is intentional and must not be replaced by an artificial green
threshold.

Candidate future thresholds, to ratify with repeated live evidence:

- hard-safety violations: exactly `0`;
- negative preservation rate: exactly `100%`;
- positive transformation rate: at least `85%` overall and `80%` per positive
  category with at least five cases;
- regression from the previous compatible release: no new hard violation,
  `0` percentage-point negative-preservation loss, and no more than `5`
  percentage points overall or `10` points per category in positive rate;
- latency: p95 no more than `2,000 ms` and no more than `25%` plus `100 ms`
  above a compatible baseline.

Until repeated live runs establish variance, the candidate positive quality,
regression, and latency thresholds remain non-blocking.
