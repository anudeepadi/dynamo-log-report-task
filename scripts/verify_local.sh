#!/usr/bin/env bash
#
# Docker-free pre-flight check for the dynamo/log-report Harbor task.
#
# This is NOT a replacement for `harbor run`. It exists because a Harbor run
# needs to pull python:3.13-slim-bookworm from Docker Hub, which is not always
# reachable (restricted egress, no daemon, offline). This script covers the
# parts of the task that do not need a container image:
#
#   1. the four-way /app/report.json path consistency the README claims
#   2. the oracle path: solution/solve.sh then tests/test.sh -> reward 1
#   3. the nop path:    no agent action, tests/test.sh        -> reward 0
#
# It runs the task's own solve.sh, solve.py, test.sh and test_outputs.py
# byte-for-byte unmodified. The absolute paths they hardcode (/app, /logs,
# /solution, /tests) are supplied by bind mounts inside a private mount
# namespace, so nothing outside the scratch directory is touched.
#
# What it still does not cover, and what only a real Harbor run can: task.toml
# parsing by TaskConfig, the environment image build, and artifact collection.
#
# Requires: Linux with unshare(1) and unprivileged user namespaces, python3,
# pytest, pytest-json-ctrf.
#
# Usage: scripts/verify_local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$REPO_ROOT/log-report"
REPORT_PATH="/app/report.json"

pass_count=0
fail_count=0

ok()   { printf '  ok    %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail_count=$((fail_count + 1)); }
head_() { printf '\n== %s ==\n' "$1"; }

# --- preconditions ----------------------------------------------------------

for tool in unshare python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool not found; this script needs Linux with unshare(1)" >&2
    exit 2
  }
done

# Probe the `pytest` on PATH, which is what tests/test.sh invokes. Checking
# `python3 -m pytest` instead would pass against a different interpreter than
# the one that actually runs, and the mismatch only surfaces as a confusing
# reward of 0 further down.
command -v pytest >/dev/null 2>&1 || {
  echo "error: pytest not on PATH (pip install pytest pytest-json-ctrf)" >&2
  exit 2
}

# Captured first rather than piped into grep -q: an early-closing reader makes
# pytest exit on SIGPIPE, which pipefail would report as a missing plugin.
pytest_help="$(pytest --help 2>/dev/null || true)"
case "$pytest_help" in
  *--ctrf*) ;;
  *)
    echo "error: $(command -v pytest) does not provide --ctrf, which" >&2
    echo "       tests/test.sh passes. Install pytest and pytest-json-ctrf" >&2
    echo "       into the same environment, e.g." >&2
    echo "         uv tool install pytest==8.4.1 --with pytest-json-ctrf==0.3.5" >&2
    exit 2
    ;;
esac

unshare --mount --map-root-user true >/dev/null 2>&1 || {
  echo "error: unprivileged mount namespaces unavailable in this environment" >&2
  exit 2
}

# --- scratch space ----------------------------------------------------------

SCRATCH="$(mktemp -d)"

# Bind mounts need their mountpoints to exist. Track the ones we create so the
# trap removes exactly those and leaves any pre-existing /app etc. alone.
CREATED_DIRS=()
for d in /app /logs /solution /tests; do
  if [ ! -e "$d" ]; then
    mkdir -p "$d"
    CREATED_DIRS+=("$d")
  fi
done

cleanup() {
  rm -rf "$SCRATCH"
  for d in "${CREATED_DIRS[@]+"${CREATED_DIRS[@]}"}"; do
    rmdir "$d" 2>/dev/null || true
  done
}
trap cleanup EXIT

# --- 1. four-way path consistency -------------------------------------------

head_ "Path consistency ($REPORT_PATH)"

check_mentions() {
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label names $needle"
  else
    bad "$label does not name $needle"
  fi
}

check_mentions "instruction.md" "$TASK_DIR/instruction.md"          "$REPORT_PATH"
check_mentions "tests/test_outputs.py" "$TASK_DIR/tests/test_outputs.py" "$REPORT_PATH"
check_mentions "solution/solve.py" "$TASK_DIR/solution/solve.py"    "$REPORT_PATH"

# task.toml needs the declaration itself inspected, not the file as a whole:
# the [metadata] prose also mentions /app/report.json, so a plain file-wide
# grep still passes when artifacts has been pointed somewhere else entirely.
artifacts_line="$(grep -E '^[[:space:]]*artifacts[[:space:]]*=' "$TASK_DIR/task.toml" || true)"

if [ -z "$artifacts_line" ]; then
  bad "task.toml declares no artifacts"
else
  case "$artifacts_line" in
    *"$REPORT_PATH"*) ok "task.toml artifacts names $REPORT_PATH" ;;
    *) bad "task.toml artifacts does not name $REPORT_PATH: $artifacts_line" ;;
  esac

  # artifacts must be a TOML array, not a bare string; a string is what made
  # harbor reject the whole directory as a task.
  case "$artifacts_line" in
    *=*\[*) ok "task.toml artifacts is an array" ;;
    *) bad "task.toml artifacts is not an array: $artifacts_line" ;;
  esac
fi

# --- scenario runner --------------------------------------------------------

# read_reward <logs_dir>
# Echoes the reward test.sh recorded, or MISSING. Guarded with -f rather than
# redirecting stderr: a failed input redirection is reported by the shell
# itself, so `< missing 2>/dev/null` still prints an error.
read_reward() {
  if [ -f "$1/verifier/reward.txt" ]; then
    tr -d '[:space:]' < "$1/verifier/reward.txt"
  else
    echo "MISSING"
  fi
}

# run_scenario <name> <run_solution: yes|no>
# Executes the task's real test.sh against a fresh /app, and echoes the reward
# that landed in /logs/verifier/reward.txt.
run_scenario() {
  local name="$1" run_solution="$2"
  local root="$SCRATCH/$name"

  mkdir -p "$root/app" "$root/logs"
  cp "$TASK_DIR/environment/access.log" "$root/app/access.log"

  # Bind copies of solution/ and tests/ rather than the originals. The files
  # are byte-for-byte identical, but pytest drops __pycache__ next to the tests
  # it imports, and the task directory must come out of a run untouched.
  cp -r "$TASK_DIR/solution" "$root/solution"
  cp -r "$TASK_DIR/tests"    "$root/tests"

  local inner="$SCRATCH/$name-inner.sh"
  cat > "$inner" <<INNER
set -eu
mount --bind "$root/app"      /app
mount --bind "$root/logs"     /logs
mount --bind "$root/solution" /solution
mount --bind "$root/tests"    /tests

if [ "$run_solution" = yes ]; then
  bash /solution/solve.sh
fi

bash /tests/test.sh
INNER

  unshare --mount --map-root-user bash "$inner" > "$root/output.txt" 2>&1 || true

  read_reward "$root/logs"
}

# --- 2. oracle --------------------------------------------------------------

head_ "Oracle (solution runs)"

oracle_reward="$(run_scenario oracle yes)"
oracle_root="$SCRATCH/oracle"

if [ "$oracle_reward" = "1" ]; then
  ok "reward.txt is 1"
else
  bad "reward.txt is '$oracle_reward', expected 1"
  sed 's/^/        /' "$oracle_root/output.txt"
fi

if [ -f "$oracle_root/logs/verifier/ctrf.json" ]; then
  ok "ctrf.json written to /logs/verifier/"
else
  bad "no ctrf.json in /logs/verifier/"
fi

if [ -f "$oracle_root/app/report.json" ]; then
  ok "solution wrote $REPORT_PATH: $(cat "$oracle_root/app/report.json")"
else
  bad "solution did not write $REPORT_PATH"
fi

# reward.txt must not be left in /app, which is where the broken test.sh put it
if [ -f "$oracle_root/app/reward.txt" ]; then
  bad "reward.txt leaked into /app"
else
  ok "no reward.txt in /app"
fi

# --- 3. nop -----------------------------------------------------------------

head_ "Nop (no agent action)"

nop_reward="$(run_scenario nop no)"
nop_root="$SCRATCH/nop"

if [ "$nop_reward" = "0" ]; then
  ok "reward.txt is 0"
else
  bad "reward.txt is '$nop_reward', expected 0"
  sed 's/^/        /' "$nop_root/output.txt"
fi

if [ -f "$nop_root/logs/verifier/ctrf.json" ]; then
  ok "ctrf.json written even on failure"
else
  bad "no ctrf.json in /logs/verifier/ on failure"
fi

# --- 4. verifier is not trivially satisfiable -------------------------------
#
# The original defect was a verifier that only checked the file exists and is
# non-empty. Confirm a well-formed but wrong report still scores 0, and that
# rewriting access.log to match a wrong report does not rescue it.

head_ "Verifier rejects a plausible wrong answer"

mkdir -p "$SCRATCH/wrong/app" "$SCRATCH/wrong/logs"
# A single-line log plus a report that honestly describes it. If the verifier
# recomputed ground truth from the log instead of hardcoding it, this passes.
head -n 1 "$TASK_DIR/environment/access.log" > "$SCRATCH/wrong/app/access.log"
cat > "$SCRATCH/wrong/app/report.json" <<'JSON'
{"total_requests": 1, "unique_ips": 1, "top_path": "/index.html"}
JSON

cp -r "$TASK_DIR/tests" "$SCRATCH/wrong/tests"

cat > "$SCRATCH/wrong-inner.sh" <<INNER
set -eu
mount --bind "$SCRATCH/wrong/app"   /app
mount --bind "$SCRATCH/wrong/logs"  /logs
mount --bind "$SCRATCH/wrong/tests" /tests
bash /tests/test.sh
INNER

unshare --mount --map-root-user bash "$SCRATCH/wrong-inner.sh" \
  > "$SCRATCH/wrong/output.txt" 2>&1 || true

wrong_reward="$(read_reward "$SCRATCH/wrong/logs")"

if [ "$wrong_reward" = "0" ]; then
  ok "rewriting access.log to match a wrong report still scores 0"
else
  bad "reward.txt is '$wrong_reward', expected 0 (verifier is gameable)"
fi

# --- summary ----------------------------------------------------------------

printf '\n%s\n' "-----------------------------------------"
printf '%d passed, %d failed\n' "$pass_count" "$fail_count"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi

cat <<'NOTE'

All local checks passed. This does not exercise task.toml parsing, the image
build, or artifact collection -- run the real thing for those:

  harbor run -p ./log-report -a oracle -y     # expect reward 1.0
  harbor run -p ./log-report --agent nop -y   # expect reward 0.0
NOTE
