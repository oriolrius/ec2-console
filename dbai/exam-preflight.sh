#!/usr/bin/env bash
# S7/S14 exam preflight (PROFILE-06 / PROFILE-10) — READ ONLY.
#
# Verifies that a student's EXISTING environment is ready for a practical exam
# using the frozen, capacity-qualified profile — WITHOUT touching coursework.
# It performs NO apply, NO upgrade, NO repair and NO substitution: a mismatched
# or unqualified profile, or a missing controller/state, FAILS readiness so the
# assessment preflight (M11) consumes an explicit pass/fail (doc-18 §6).
#
# Usage:
#   dbai/exam-preflight.sh <environment-id> [--exam-profile exam-s7-practical]
#                          [--emit <assessment-manifest.json>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CATALOG="${SCRIPT_DIR}/profiles/catalog.yaml"

state_root() {
  case "$(uname -s)" in
    Darwin) printf '%s/ec2-console/dbai' "${XDG_STATE_HOME:-$HOME/Library/Application Support}" ;;
    *)      printf '%s/ec2-console/dbai' "${XDG_STATE_HOME:-$HOME/.local/state}" ;;
  esac
}
manifest_path() { printf '%s/%s/environment.json' "$(state_root)" "$1"; }

env_id=""; exam_profile="exam-s7-practical"; emit=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exam-profile) exam_profile="${2:-}"; shift 2 ;;
    --emit)         emit="${2:-}"; shift 2 ;;
    -*)             echo "unknown argument: $1" >&2; exit 2 ;;
    *)              env_id="$1"; shift ;;
  esac
done
[ -n "$env_id" ] || { echo "usage: exam-preflight.sh <environment-id> [--exam-profile <name>] [--emit <path>]" >&2; exit 2; }

fail=0
pass() { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

echo "== dbai exam preflight: ${env_id} (profile ${exam_profile}) =="
echo "note: READ ONLY — preserves branches, files, faults, workloads and evidence; no upgrade, no repair, no substitute."

manifest="$(manifest_path "$env_id")"

# --- 1. Exam profile is frozen and selects a capacity-qualified base (AC#1) ---
sel_base="$(CATALOG="$CATALOG" EXAM="$exam_profile" python3 - <<'PY'
import os, yaml
cat = yaml.safe_load(open(os.environ["CATALOG"]))
profs = cat.get("profiles", [])
prof = next((p for p in profs if p.get("name") == os.environ["EXAM"]), None)
if not prof:
    print("ERR:no-exam-profile"); raise SystemExit
if prof.get("kind") != "practical":
    print("ERR:not-practical"); raise SystemExit
sels = prof.get("selects") or []
size = prof.get("instance_size")
# the qualified compute base is the SELECTED non-exam profile whose instance_size
# matches the exam (containers for S7/t3.medium, operations for S14/t3.large).
by_ver = {p.get("version"): p for p in profs}
base = next((s for s in sels
             if by_ver.get(s) and by_ver[s].get("instance_size") == size
             and by_ver[s].get("kind") != "practical"), "")
print(base or "ERR:no-base")
PY
)"
case "$sel_base" in
  ERR:*) bad "exam profile '${exam_profile}' invalid: ${sel_base#ERR:}" ;;
  "")    bad "exam profile '${exam_profile}' selects no containers base" ;;
  *)     pass "exam profile '${exam_profile}' is practical and selects '${sel_base}'" ;;
esac

# base profile exists and is qualified by a capacity task (verification_evidence)
if [ -n "$sel_base" ] && [ "${sel_base#ERR:}" = "$sel_base" ]; then
  base_ok="$(CATALOG="$CATALOG" BASE="${sel_base%%-*}" VER="$sel_base" python3 - <<'PY'
import os, yaml
cat = yaml.safe_load(open(os.environ["CATALOG"]))
p = next((p for p in cat.get("profiles", []) if p.get("version") == os.environ["VER"]), None)
print(p.get("verification_evidence","") if p else "")
PY
)"
  [ -n "$base_ok" ] && pass "base '${sel_base}' carries capacity evidence (${base_ok})" \
                    || bad "base '${sel_base}' has no capacity verification_evidence — unqualified"
fi

# --- 2. Environment identity exists (no silent fresh substitute) (AC#4) ---
if [ ! -f "$manifest" ]; then
  bad "no environment manifest for '${env_id}' — refusing (never provision a fresh substitute for an exam)"
  echo; echo "exam-preflight: NOT READY."; exit 1
fi
pass "environment manifest present (existing workspace, not a substitute)"

# read manifest fields (read only)
read_m() { M="$manifest" F="$1" python3 -c 'import json,os;print(json.load(open(os.environ["M"])).get(os.environ["F"]) or "")'; }
acct_m="$(read_m aws_account)"; pver="$(read_m profile_version)"
iid="$(read_m instance_id)"; mrev="$(read_m module_revision)"
bsha="$(read_m bootstrap_template_sha256)"; region="$(read_m aws_region)"
alloc="$(read_m eip_allocation_id)"

# --- 3. Selected/running profile matches the qualified base (AC#1/#4) ---
if [ "$pver" = "$sel_base" ]; then
  pass "recorded profile '${pver}' matches the qualified exam base"
else
  bad "recorded profile '${pver}' != qualified base '${sel_base}' — mismatched/unqualified, not silently upgraded"
fi
[ -n "$mrev" ]  && pass "module revision recorded (${mrev})"            || bad "no module revision recorded"
[ -n "$bsha" ]  && pass "bootstrap template sha256 recorded"            || bad "no bootstrap sha256 recorded"
[ -n "$alloc" ] && pass "retained EIP allocation recorded (${alloc})"  || bad "no retained EIP allocation recorded (identity not preserved)"

# --- 4. Controller/backend accessibility (AC#3) ---
sr="$(state_root)/${env_id}"
[ -r "${sr}/workspace.tfstate" ] && pass "controller workspace state readable" || bad "workspace state missing/unreadable"
[ -r "${sr}/address.tfstate" ]   && pass "controller address state readable"   || bad "address state missing/unreadable"

# --- 5. Account + connectivity (read-only describe) (AC#3) ---
if command -v aws >/dev/null 2>&1; then
  sess_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
  if [ -n "$sess_acct" ]; then
    [ "$sess_acct" = "$acct_m" ] && pass "session account ${sess_acct} matches manifest" \
                                 || bad "account mismatch: session ${sess_acct} != manifest ${acct_m}"
    if [ -n "$iid" ]; then
      st="$(aws ec2 describe-instances --region "$region" --instance-ids "$iid" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo 'unknown')"
      [ "$st" = "running" ] && pass "workspace instance ${iid} is running (read-only check)" \
                            || bad "workspace instance ${iid} state=${st} (not running)"
    fi
  else
    bad "no AWS session — cannot verify account/connectivity (refuse rather than assume)"
  fi
else
  bad "aws CLI unavailable — cannot verify connectivity"
fi

# --- 6. Assessment manifest contribution (versions only; AC#5) ---
if [ -n "$emit" ] && [ "$fail" -eq 0 ]; then
  EMIT="$emit" ENVID="$env_id" EXAM="$exam_profile" BASE="$sel_base" PVER="$pver" \
  MREV="$mrev" BSHA="$bsha" IID="$iid" python3 - <<'PY'
import json, os, datetime
doc = {
  "schema": "dbai/assessment-preflight/v1",
  "environment_id": os.environ["ENVID"],
  "exam_profile": os.environ["EXAM"],
  "qualified_base": os.environ["BASE"],
  "recorded_profile_version": os.environ["PVER"],
  "module_revision": os.environ["MREV"],
  "bootstrap_template_sha256": os.environ["BSHA"],
  "instance_id": os.environ["IID"],
  "verdict": "READY",
  "preflight_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "discipline": "stop/preserve until evidence and grading allow cleanup; no repair/substitution performed",
}
json.dump(doc, open(os.environ["EMIT"], "w"), indent=2)
print(f"  emitted assessment manifest -> {os.environ['EMIT']}")
PY
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "exam-preflight: READY. Stop/preserve the environment until evidence and grading allow cleanup."
  exit 0
else
  echo "exam-preflight: NOT READY (see FAIL lines). Do not provision a substitute; resolve out-of-band and re-run."
  exit 1
fi
