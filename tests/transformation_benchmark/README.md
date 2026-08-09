# Transformation benchmark foundation

This directory contains a privacy-safe, synthetic benchmark for Feature Set A
text modes. It is intentionally independent of production Zig APIs, provider
prompts, provider schemas, and live Groq. Version 1 is a deterministic corpus
and scorer contract, not a release gate.

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

A later production adapter writes one object per attempted corpus case:

```json
{"schema_version":1,"case_id":"clean-filler-um","outcome":"applied","output":"Please send the synthetic report.","latency_ms":18.4,"adapter":{"name":"reference-adapter","version":"dev"},"provider":{"name":"groq","model":"configured-model"},"plan":{"schema_version":1,"operations":[]}}
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
future adapter must inject the named synthetic plan-validation outcome after
model transport, without relying on a provider to emit a particular malformed
response. Returning anything except a source-exact fallback is a hard scenario
failure.

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

## Later production and live-job integration

The production adapter should live with the future transformation API. It will
map each corpus record to that API's mode/input, time only the transformation
operation, and project the returned output and validated plan into the result
contract above. It must redact credentials and provider bodies and must never
persist real dictation. A manually dispatched, non-release-blocking workflow
can then follow the Deepgram pattern: pin the exact benchmark SHA, run unit
tests, execute the adapter with repository secrets, download a prior compatible
report, render JSON/Markdown, and retain privacy-safe artifacts. Do not add that
job until the production API and plan validator have merged.

Proposed initial release thresholds, to ratify with repeated live evidence:

- hard-safety violations: exactly `0`;
- negative preservation rate: exactly `100%`;
- positive transformation rate: at least `85%` overall and `80%` per positive
  category with at least five cases;
- regression from the previous compatible release: no new hard violation,
  `0` percentage-point negative-preservation loss, and no more than `5`
  percentage points overall or `10` points per category in positive rate;
- latency: p95 no more than `2,000 ms` and no more than `25%` plus `100 ms`
  above a compatible baseline.

Until live variance is measured over repeated runs and platform end-to-end
evidence is connected, these are proposals only and this benchmark must not be
wired into the release workflow.
