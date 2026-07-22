# dynamo/log-report — repaired Terminal-Bench 2 (Harbor) task

The task in `log-report/` parses an Apache-style access log into a small JSON report.
It was handed over with several authoring defects; this repo contains the repaired task
plus the verification runs that prove it grades honestly.

## Verification

```
harbor run -p ./log-report -a oracle -y     # reward 1.0  (jobs/verify-oracle)
harbor run -p ./log-report --agent nop -y   # reward 0.0  (jobs/verify-nop)
```

Both runs are committed under `jobs/` with their `verifier/reward.txt` and
`verifier/ctrf.json`.

## Defects found and fixed

| # | Defect | Fix |
|---|--------|-----|
| 1 | `task.toml`: `artifacts` was a string (`"/app/out.json"`) instead of an array, and named a file the task never produces | `artifacts = ["/app/report.json"]` |
| 2 | `environment/Dockerfile` used the unpinned, non-approved `python:latest` | Pinned to `python:3.13-slim-bookworm@sha256:9d7f2875…` |
| 3 | The agent image leaked the reference solution via `COPY solution_hint.py` | Deleted `environment/solution_hint.py` and the `COPY` line |
| 4 | The verifier was gameable — it only asserted `report.json` exists and is non-empty | Rewrote `tests/test_outputs.py` to assert the actual values against hardcoded ground truth |
| 5 | `tests/test.sh` wrote `reward.txt` to `/app/` and never produced `ctrf.json` | Writes both `reward.txt` and `ctrf.json` to `/logs/verifier/` |
| 6 | `instruction.md` was vague prose — no output path, no schema, no success criteria | Rewrote with the absolute path, exact JSON schema, and 4 numbered criteria matching the verifier 1:1 |

Defect 1 was the reason `harbor run -p log-report` failed outright with
`ValueError: Either datasets or tasks must be provided.` — the malformed `artifacts`
value failed `TaskConfig` validation, so Harbor did not recognize the directory as a
task at all.

### Not defects

The `access.log` input is intact, the task needs no network at runtime, `solution/solve.sh`
computes the correct answer, and `memory_mb = 2048` is ample for the verifier.

## Four-way consistency

`/app/report.json` is the path named in `instruction.md`, declared in `task.toml`
`artifacts`, asserted by `tests/test_outputs.py`, and written by `solution/solve.py`.
