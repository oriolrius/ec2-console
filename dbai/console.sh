#!/usr/bin/env bash
#
# dbai console — controller CLI for the DBAI course Terraform path (doc-18).
#
# This is the DBAI *entry point*. It is deliberately separate from the legacy
# root-level CloudFormation + Ansible path (README.md "Deploy"/"Tear down"),
# which is unchanged and remains the supported route for non-course consumers.
#
# Implemented operations:
#   doctor           Diagnose controller prerequisites/session (ENV-05).
#   select-backend   Select the Terraform backend for a fresh course
#                    environment and record the selection (ENV-01).
#   init-address     Allocate/reuse the persistent EIP in its own state (ENV-03).
#   initialize       Create or reconnect the workspace VM (ENV-06).
#   check-keys       Phase-aware access-key readiness (RECOVERY-02).
#   destroy-address  Distinct address (EIP) cleanup (ENV-03).
#   status           Print the recorded environment manifest (ENV-02).
#   terraform-cmd    Print the exact native Terraform invocation (ENV-04).
#   unlock           Release a stale workspace lock (ENV-04 recovery).
#   help             Show usage.
#
# Later M01 tasks add: plan, apply, start/stop, rebuild, workspace destroy,
# adopt-student-root, final-cleanup. Do NOT reference unimplemented commands
# in student-facing material.
set -euo pipefail

# --- locations -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}/terraform/workspace"
ADDRESS_ROOT="${SCRIPT_DIR}/terraform/address"
PROFILES_CATALOG="${SCRIPT_DIR}/profiles/catalog.yaml"
BOOTSTRAP_TEMPLATE="${WORKSPACE_ROOT}/templates/bootstrap.cloudinit.yaml.tftpl"
MANIFEST_SCHEMA="dbai/environment-manifest/v2"

# Controller state root: per-student, outside any Git repository (doc-18 §2).
# ENV-05 refines macOS/WSL2 bootstrap; this resolves all three today.
controller_state_root() {
  local base
  case "$(uname -s)" in
    Darwin) base="${XDG_STATE_HOME:-$HOME/Library/Application Support}" ;;
    *)      base="${XDG_STATE_HOME:-$HOME/.local/state}" ;;  # Linux and WSL2
  esac
  printf '%s/ec2-console/dbai' "$base"
}

env_state_dir()   { printf '%s/%s' "$(controller_state_root)" "$1"; }
manifest_path()   { printf '%s/environment.json' "$(env_state_dir "$1")"; }
tfstate_path()    { printf '%s/workspace.tfstate' "$(env_state_dir "$1")"; }
address_state_path() { printf '%s/address.tfstate' "$(env_state_dir "$1")"; }

# sha256 of the bootstrap template, so profile drift is visible (doc-18).
bootstrap_hash() {
  [ -f "$BOOTSTRAP_TEMPLATE" ] || die "bootstrap template missing: $BOOTSTRAP_TEMPLATE"
  printf 'sha256:%s' "$(sha256sum "$BOOTSTRAP_TEMPLATE" | cut -d' ' -f1)"
}

# Git revision of the ec2-console checkout (non-secret provenance).
ec2_console_revision() {
  git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown'
}

# --- helpers ---------------------------------------------------------------
log()  { printf '[dbai] %s\n' "$*" >&2; }
die()  { printf '[dbai] ERROR: %s\n' "$*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# --- one active root + shared lock (ENV-04) --------------------------------
# Read one top-level manifest field (empty if absent/null; non-fatal).
manifest_field() {
  local manifest; manifest="$(manifest_path "$1")"
  [ -f "$manifest" ] || return 0
  MANIFEST="$manifest" FIELD="$2" python3 - <<'PY'
import json, os
try:
    v = json.load(open(os.environ["MANIFEST"])).get(os.environ["FIELD"])
    print("" if v is None else v)
except Exception:
    pass
PY
}

# Read one field from the manifest's persisted inputs block (empty if absent).
input_field() {
  local manifest; manifest="$(manifest_path "$1")"
  [ -f "$manifest" ] || return 0
  MANIFEST="$manifest" FIELD="$2" python3 - <<'PY'
import json, os
try:
    v = (json.load(open(os.environ["MANIFEST"])).get("inputs") or {}).get(os.environ["FIELD"])
    print("" if v is None else v)
except Exception:
    pass
PY
}

# Resolve THE one active root for the environment. A caller requesting a
# different (stale) root is rejected, not applied (AC#1).
resolve_active_root() {
  local env_id="$1" requested="${2:-}" active
  active="$(manifest_field "$env_id" active_root)"
  [ -n "$active" ] || die "no active root recorded for '${env_id}' (run select-backend first)"
  if [ -n "$requested" ] && [ "$requested" != "$active" ]; then
    die "requested root '${requested}' is not the active root '${active}' for '${env_id}'; refusing to operate on a stale root."
  fi
  printf '%s' "$active"
}

# Portable advisory lock (Linux/macOS/WSL2) shared by all controller
# mutations. Native Terraform additionally holds the local backend's own state
# lock on the shared state file; both routes therefore serialize (doc-18 §3).
LOCK_DIR=""
acquire_lock() {
  local env_id="$1" op="$2" lockdir; lockdir="$(env_state_dir "$env_id")/.dbai.lock"
  mkdir -p "$(env_state_dir "$env_id")"
  if ! mkdir "$lockdir" 2>/dev/null; then
    local owner; owner="$(cat "$lockdir/owner" 2>/dev/null || echo 'unknown')"
    die "workspace '${env_id}' is locked by another operation (${owner}). If a run was interrupted, recover with: dbai/console.sh unlock ${env_id}"
  fi
  LOCK_DIR="$lockdir"
  printf 'pid=%s op=%s time=%s\n' "$$" "$op" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lockdir/owner" 2>/dev/null || true
  trap release_lock EXIT INT TERM
}
release_lock() { [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_DIR=""; }

# Read one field of a named profile from the catalog (empty if absent).
profile_field() {
  local name="$1" field="$2"
  CATALOG="$PROFILES_CATALOG" NAME="$name" FIELD="$field" python3 - <<'PY'
import os, yaml
try:
    cat = yaml.safe_load(open(os.environ["CATALOG"]))
    for p in cat.get("profiles", []):
        if p.get("name") == os.environ["NAME"]:
            v = p.get(os.environ["FIELD"])
            print("" if v is None else v); break
except Exception:
    pass
PY
}

# Detect a controller that is ONLY the disposable managed VM (doc-18 §2).
on_managed_vm() {
  [ -f /etc/dbai-bootstrap ] && return 0
  [ -n "${DBAI_SIMULATE_VM:-}" ] && return 0
  return 1
}

# Write the complete non-secret environment manifest (doc-18 §3), preserving
# any resource identities a previous run recorded. No key/token/credential
# values — key references are controller-local paths only.
write_manifest() {
  local env_id="$1" account="$2" region="$3"
  local manifest tfstate addrstate boot rev
  manifest="$(manifest_path "$env_id")"
  tfstate="$(tfstate_path "$env_id")"
  addrstate="$(address_state_path "$env_id")"
  boot="$(bootstrap_hash)"
  rev="$(ec2_console_revision)"
  MANIFEST="$manifest" ENV_ID="$env_id" ACCOUNT="$account" REGION="$region" \
  SCHEMA="$MANIFEST_SCHEMA" ADDR="$addrstate" WORK="$tfstate" BOOT="$boot" REV="$rev" \
  python3 - <<'PY'
import json, os, datetime
path = os.environ["MANIFEST"]
prev = {}
if os.path.exists(path):
    try: prev = json.load(open(path))
    except Exception: prev = {}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
env_id = os.environ["ENV_ID"]
m = {
    "schema": os.environ["SCHEMA"],
    "baseline_version": "1.0.0",
    "profile_version": prev.get("profile_version"),
    "environment_id": env_id,
    "aws_account": os.environ["ACCOUNT"],
    "aws_region": os.environ["REGION"],
    "active_root": "dbai/terraform/workspace",
    "ec2_console": {"sha": os.environ["REV"]},
    "module_revision": prev.get("module_revision"),
    "backend": "local",
    "backend_paths": {"address": os.environ["ADDR"], "workspace": os.environ["WORK"]},
    "eip_allocation_id": prev.get("eip_allocation_id"),
    "instance_id": prev.get("instance_id"),
    "allowed_tags": {
        "Project": "ec2-console", "Course": "dbai",
        "ManagedBy": "terraform", "Environment": env_id,
    },
    "connection": prev.get("connection", {"public_ip": None, "ssh": None}),
    "bootstrap_template_sha256": os.environ["BOOT"],
    "key_refs": prev.get("key_refs", {
        "ssh_private_key_path": None, "deploy_public_key_path": None,
    }),
    "owner": "terraform",
    "selected_at": prev.get("selected_at", now),
    "updated_at": now,
}
old = os.umask(0o077)
try:
    with open(path, "w") as f:
        json.dump(m, f, indent=2)
        f.write("\n")
finally:
    os.umask(old)
PY
}

# Merge JSON fields (from $2) into the manifest, refreshing updated_at.
merge_manifest() {
  local env_id="$1" fields="$2" manifest; manifest="$(manifest_path "$env_id")"
  MANIFEST="$manifest" FIELDS="$fields" python3 - <<'PY'
import json, os, datetime
path = os.environ["MANIFEST"]
m = json.load(open(path))
m.update(json.loads(os.environ["FIELDS"]))
m["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
old = os.umask(0o077)
try:
    with open(path, "w") as f:
        json.dump(m, f, indent=2); f.write("\n")
finally:
    os.umask(old)
PY
}

# Load a manifest by id and fail CLEARLY on missing/inconsistent identity
# metadata — never silently fall back to a different environment (AC#5).
verify_manifest() {
  local env_id="$1" manifest
  manifest="$(manifest_path "$env_id")"
  [ -f "$manifest" ] || die "no environment manifest for '${env_id}' at ${manifest} (nothing selected, or wrong controller/state root)"
  MANIFEST="$manifest" WANT="$env_id" SCHEMA="$MANIFEST_SCHEMA" python3 - <<'PY' || exit 1
import json, os, sys
path, want, schema = os.environ["MANIFEST"], os.environ["WANT"], os.environ["SCHEMA"]
try:
    m = json.load(open(path))
except Exception as e:
    sys.stderr.write(f"[dbai] ERROR: manifest {path} is not valid JSON: {e}\n"); sys.exit(1)
got = m.get("environment_id")
if got != want:
    sys.stderr.write(f"[dbai] ERROR: manifest environment_id {got!r} != requested {want!r}; refusing to use a different environment.\n"); sys.exit(1)
if not str(m.get("schema","")).startswith("dbai/environment-manifest/"):
    sys.stderr.write(f"[dbai] ERROR: unrecognized manifest schema {m.get('schema')!r}.\n"); sys.exit(1)
for req in ("aws_account","aws_region","active_root","backend_paths","bootstrap_template_sha256"):
    if not m.get(req):
        sys.stderr.write(f"[dbai] ERROR: manifest missing required field {req!r}; inconsistent metadata.\n"); sys.exit(1)
PY
}

validate_prereqs() {
  require_tool terraform
  require_tool aws
  require_tool python3
  require_tool sha256sum
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no valid AWS session; run your sandbox login first"
}

# CF-ownership guard (ENV-R002): a CloudFormation-owned environment must never
# be attached to the Terraform backend as a new course environment. Returns 0
# (guard clear) when NO active CloudFormation stack owns this identity.
assert_not_cloudformation_owned() {
  local env_id="$1" region="$2" status
  # DELETE_COMPLETE stacks are gone and do not own resources; every other
  # status means CloudFormation still owns this environment.
  status="$(aws cloudformation describe-stacks \
    --stack-name "$env_id" --region "$region" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
  if [ -n "$status" ] && [ "$status" != "None" ] && [ "$status" != "DELETE_COMPLETE" ]; then
    die "environment '${env_id}' is owned by a CloudFormation stack (status: ${status}). Refusing to attach it to the Terraform backend as a new course environment. Retire or migrate it via the separate route documented in dbai/README.md (§ Legacy environments). No resources were modified."
  fi
}

# --- operations ------------------------------------------------------------
cmd_select_backend() {
  local env_id="" region="eu-west-1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment-id) env_id="${2:-}"; shift 2 ;;
      --region)         region="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "--environment-id is required"

  validate_prereqs
  local account
  account="$(aws sts get-caller-identity --query Account --output text)"

  # Guard BEFORE touching Terraform or any resource.
  assert_not_cloudformation_owned "$env_id" "$region"

  local state_dir tfstate manifest
  state_dir="$(env_state_dir "$env_id")"
  tfstate="$(tfstate_path "$env_id")"
  manifest="$(manifest_path "$env_id")"
  mkdir -p "$state_dir"
  chmod 700 "$(controller_state_root)" "$state_dir" 2>/dev/null || true

  # Serialize workspace mutations behind the shared lock (ENV-04).
  acquire_lock "$env_id" "select-backend"

  log "selecting Terraform (local) backend for environment '${env_id}'"
  terraform -chdir="$WORKSPACE_ROOT" init -input=false -reconfigure \
    -backend-config="path=${tfstate}" >&2

  # Record the complete non-secret environment manifest (doc-18 §3).
  write_manifest "$env_id" "$account" "$region"
  log "environment manifest recorded: ${manifest}"
}

cmd_status() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh status <environment-id>"
  verify_manifest "$env_id"
  cat "$(manifest_path "$env_id")"
}

# Allocate (or reuse) the environment's persistent Elastic IP in its own
# independent state, and record the allocation id in the manifest (ENV-03).
cmd_init_address() {
  local env_id="" region="eu-west-1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment-id) env_id="${2:-}"; shift 2 ;;
      --region)         region="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "--environment-id is required"
  validate_prereqs
  verify_manifest "$env_id"
  acquire_lock "$env_id" "init-address"
  local addrstate; addrstate="$(address_state_path "$env_id")"

  log "initializing address state for '${env_id}'"
  terraform -chdir="$ADDRESS_ROOT" init -input=false -reconfigure \
    -backend-config="path=${addrstate}" >&2
  # apply is idempotent: an existing allocation in state is reused, not
  # duplicated. State holds exactly one aws_eip.
  terraform -chdir="$ADDRESS_ROOT" apply -input=false -auto-approve \
    -var "environment_id=${env_id}" -var "aws_region=${region}" >&2

  local alloc ip
  alloc="$(terraform -chdir="$ADDRESS_ROOT" output -raw eip_allocation_id)"
  ip="$(terraform -chdir="$ADDRESS_ROOT" output -raw public_ip)"
  merge_manifest "$env_id" "$(printf '{"eip_allocation_id":"%s","connection":{"public_ip":"%s","ssh":null}}' "$alloc" "$ip")"
  log "address ready: allocation ${alloc}, public IP ${ip} (recorded in manifest)"
}

# Create the workspace or reconnect to an already identified one (ENV-06).
# Validates credentials/tools/profile, applies the workspace with the profile
# inputs, and records module/profile/resource identity. Idempotent: a healthy
# existing environment reconnects with no new VM/address. Failure propagates —
# a failed apply never reports "ready".
cmd_initialize() {
  local env_id="" profile="" region="eu-west-1" sshkey="" deploykey="" instrkey="" sshprivkey=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment-id)        env_id="${2:-}"; shift 2 ;;
      --profile)               profile="${2:-}"; shift 2 ;;
      --ssh-public-key)        sshkey="${2:-}"; shift 2 ;;
      --deploy-public-key)     deploykey="${2:-}"; shift 2 ;;
      --instructor-public-key) instrkey="${2:-}"; shift 2 ;;
      --ssh-private-key)       sshprivkey="${2:-}"; shift 2 ;;
      --region)                region="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ]  || die "--environment-id is required"
  [ -n "$profile" ] || die "--profile is required (see dbai/profiles/catalog.yaml)"
  [ -n "$sshkey" ]  || die "--ssh-public-key is required"

  validate_prereqs
  verify_manifest "$env_id"

  # Account match (AC#4): the session must match the manifest's account.
  local acct manifest_acct
  acct="$(aws sts get-caller-identity --query Account --output text)"
  manifest_acct="$(manifest_field "$env_id" aws_account)"
  [ "$acct" = "$manifest_acct" ] || die "account mismatch: session ${acct} != manifest ${manifest_acct}. Refusing; environment NOT ready."

  # Resolve the profile from the catalog (AC#1/#4).
  local inst boot boot_abs pver
  inst="$(profile_field "$profile" instance_size)"
  [ -n "$inst" ] || die "unknown profile '${profile}' (no instance_size in catalog)."
  boot="$(profile_field "$profile" bootstrap_template)"
  [ -n "$boot" ] || boot="dbai/terraform/workspace/templates/bootstrap.cloudinit.yaml.tftpl"
  boot_abs="${SCRIPT_DIR}/../${boot}"
  [ -f "$boot_abs" ] || die "profile bootstrap template not found: ${boot_abs}"
  pver="$(profile_field "$profile" version)"

  local alloc; alloc="$(manifest_field "$env_id" eip_allocation_id)"
  [ -n "$alloc" ] || die "no EIP allocated for '${env_id}'; run init-address first."

  local tfstate; tfstate="$(tfstate_path "$env_id")"
  acquire_lock "$env_id" "initialize"

  log "initializing workspace for '${env_id}' (profile ${profile}, ${inst})"
  terraform -chdir="$WORKSPACE_ROOT" init -input=false -reconfigure \
    -backend-config="path=${tfstate}" >&2

  local args=(-input=false -auto-approve
    -var "student_id=${env_id}" -var "aws_region=${region}"
    -var "ssh_public_key_path=${sshkey}" -var "eip_allocation_id=${alloc}"
    -var "instance_type=${inst}" -var "bootstrap_template_path=${boot_abs}")
  [ -n "$deploykey" ] && args+=(-var "deploy_public_key_path=${deploykey}")
  [ -n "$instrkey" ]  && args+=(-var "instructor_public_key_path=${instrkey}")
  terraform -chdir="$WORKSPACE_ROOT" apply "${args[@]}" >&2

  local iid ip rev
  iid="$(terraform -chdir="$WORKSPACE_ROOT" output -raw instance_id)"
  ip="$(terraform -chdir="$WORKSPACE_ROOT" output -raw public_ip)"
  rev="$(ec2_console_revision)"

  # Persist resource ids + the non-secret inputs needed to plan/apply again.
  merge_manifest "$env_id" "$(printf '{"instance_id":"%s","module_revision":"%s","profile_version":"%s","connection":{"public_ip":"%s","ssh":"ssh ubuntu@%s"},"inputs":{"profile":"%s","ssh_public_key_path":"%s","deploy_public_key_path":%s,"instructor_public_key_path":%s,"instance_type":"%s","bootstrap_template_path":"%s","region":"%s"}}' \
    "$iid" "$rev" "$pver" "$ip" "$ip" "$profile" "$sshkey" \
    "$([ -n "$deploykey" ] && printf '"%s"' "$deploykey" || echo null)" \
    "$([ -n "$instrkey" ] && printf '"%s"' "$instrkey" || echo null)" \
    "$inst" "$boot_abs" "$region")"

  # Readiness (ENV-07): boot readiness first; connection is reported ONLY after
  # it passes. A failure here is NOT labelled ready and propagates nonzero.
  wait_readiness "$env_id" "$iid" "$ip" "$sshprivkey"

  log "workspace READY: instance ${iid}, public IP ${ip}, profile ${profile}"
}

# Wait for boot (and optional profile) readiness. Identifies the responsible
# layer on failure and never reports ready (ENV-07, ENV-R017/R018).
wait_readiness() {
  local env_id="$1" iid="$2" ip="$3" privkey="$4" region
  region="$(manifest_field "$env_id" aws_region)"
  log "waiting for boot readiness (instance status checks) for ${iid}..."
  if ! aws ec2 wait instance-status-ok --instance-ids "$iid" --region "$region" 2>/dev/null; then
    die "[layer: readiness] instance ${iid} did not reach status-ok; NOT ready."
  fi
  if [ -n "$privkey" ]; then
    log "probing profile readiness over SSH..."
    local sshopt="-i $privkey -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
    if ! ssh $sshopt "ubuntu@${ip}" 'cloud-init status --wait' >/dev/null 2>&1; then
      die "[layer: bootstrap] cloud-init did not complete on ${ip}; NOT ready."
    fi
  fi
}

# Native Terraform plan for the active root, preserving detailed-exitcode
# (0 = no change, 2 = change, 1 = error) and reusing the persisted inputs.
cmd_plan() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh plan <environment-id>"
  validate_prereqs
  verify_manifest "$env_id"
  local tfstate alloc inst boot sshkey region deploykey instrkey
  tfstate="$(tfstate_path "$env_id")"
  alloc="$(manifest_field "$env_id" eip_allocation_id)"
  inst="$(input_field "$env_id" instance_type)"
  boot="$(input_field "$env_id" bootstrap_template_path)"
  sshkey="$(input_field "$env_id" ssh_public_key_path)"
  region="$(input_field "$env_id" region)"; region="${region:-eu-west-1}"
  deploykey="$(input_field "$env_id" deploy_public_key_path)"
  instrkey="$(input_field "$env_id" instructor_public_key_path)"
  [ -n "$inst" ] && [ -n "$sshkey" ] || die "no persisted inputs; run initialize first"

  terraform -chdir="$WORKSPACE_ROOT" init -input=false -reconfigure \
    -backend-config="path=${tfstate}" >&2
  local args=(-input=false -detailed-exitcode
    -var "student_id=${env_id}" -var "aws_region=${region}"
    -var "ssh_public_key_path=${sshkey}" -var "eip_allocation_id=${alloc}"
    -var "instance_type=${inst}" -var "bootstrap_template_path=${boot}")
  [ -n "$deploykey" ] && args+=(-var "deploy_public_key_path=${deploykey}")
  [ -n "$instrkey" ]  && args+=(-var "instructor_public_key_path=${instrkey}")

  set +e
  terraform -chdir="$WORKSPACE_ROOT" plan "${args[@]}"
  local rc=$?
  set -e
  case "$rc" in
    0) log "plan: no changes (detailed-exitcode 0)" ;;
    2) log "plan: changes pending (detailed-exitcode 2)" ;;
    *) log "plan: ERROR (exit ${rc})" ;;
  esac
  return "$rc"
}

# Distinct address cleanup (ENV-03). A retained address is billable; full
# ordered final cleanup is ENV-10.
cmd_destroy_address() {
  local env_id="${1:-}" region="${2:-eu-west-1}"
  [ -n "$env_id" ] || die "usage: console.sh destroy-address <id> [region]"
  validate_prereqs
  verify_manifest "$env_id"
  acquire_lock "$env_id" "destroy-address"
  local addrstate; addrstate="$(address_state_path "$env_id")"
  [ -f "$addrstate" ] || die "no address state for '${env_id}'"
  log "destroying address (EIP) for '${env_id}'"
  terraform -chdir="$ADDRESS_ROOT" init -input=false -reconfigure \
    -backend-config="path=${addrstate}" >&2
  terraform -chdir="$ADDRESS_ROOT" destroy -input=false -auto-approve \
    -var "environment_id=${env_id}" -var "aws_region=${region}" >&2
  merge_manifest "$env_id" '{"eip_allocation_id":null,"connection":{"public_ip":null,"ssh":null}}'
  log "address destroyed; allocation cleared from manifest"
}

# Print the EXACT native Terraform invocation + backend config for the active
# root, so students run native Terraform against the same backend and lock
# (doc-18 §3; ENV-04 native-CLI route).
cmd_terraform_cmd() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh terraform-cmd <environment-id>"
  verify_manifest "$env_id"
  local active tfstate
  active="$(resolve_active_root "$env_id")"
  tfstate="$(tfstate_path "$env_id")"
  cat <<TXT
# Active root: ${active}   (backend: local, shared state + lock)
# Run native Terraform against the SAME state/lock as the controller:
terraform -chdir=${SCRIPT_DIR}/terraform/workspace init -backend-config="path=${tfstate}"
terraform -chdir=${SCRIPT_DIR}/terraform/workspace plan
# Recover a stale lock (only when no operation is running): console.sh unlock ${env_id}
TXT
}

# Release a stale workspace lock left by an interrupted run (ENV-04 recovery).
cmd_unlock() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh unlock <environment-id>"
  local lockdir; lockdir="$(env_state_dir "$env_id")/.dbai.lock"
  [ -d "$lockdir" ] || { log "no lock held for '${env_id}'"; return 0; }
  log "releasing lock: $(cat "$lockdir/owner" 2>/dev/null || echo unknown)"
  rm -rf "$lockdir"
}

# Phase-aware access-key readiness (RECOVERY-02). Student access key is
# required from S2; the S5 deploy key from S5; the instructor key from S6. A
# key missing when its phase requires it fails readiness WITHOUT blocking
# earlier phases.
cmd_check_keys() {
  local phase="" student="" deploy="" instructor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)      phase="${2:-}"; shift 2 ;;
      --student)    student="${2:-}"; shift 2 ;;
      --deploy)     deploy="${2:-}"; shift 2 ;;
      --instructor) instructor="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$phase" ] || die "usage: console.sh check-keys --phase S2 [--student p] [--deploy p] [--instructor p]"
  local n; n="$(printf '%s' "$phase" | tr -dc '0-9')"
  [ -n "$n" ] || die "phase must look like S2..S14"

  local ok=1
  _need() { # name path
    if [ -z "$2" ] || [ ! -f "$2" ]; then
      log "MISSING required $1 key for ${phase}"; ok=0
    else
      log "OK $1 key enrolled"
    fi
  }
  _need "student access" "$student"                 # required from S2
  [ "$n" -ge 5 ] && _need "S5 deploy" "$deploy"     # required from S5
  [ "$n" -ge 6 ] && _need "instructor" "$instructor" # required from S6

  [ "$ok" = 1 ] || die "access keys not ready for ${phase} (earlier phases are unaffected)."
  log "access keys ready for ${phase}."
}

# Diagnose a controller before provisioning is reported available (ENV-05).
cmd_doctor() {
  local env_id="" region="eu-west-1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment-id) env_id="${2:-}"; shift 2 ;;
      --region)         region="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  # The controller must survive a lab-VM destroy: refuse if it IS the VM.
  if on_managed_vm; then
    die "this looks like the disposable managed VM; the controller must run on your laptop (Linux/macOS/WSL2), not only inside the VM (doc-18 §2)."
  fi

  local ok=1
  for t in terraform aws python3 sha256sum ssh git; do
    if command -v "$t" >/dev/null 2>&1; then
      log "prereq OK: $t"
    else
      log "prereq MISSING: $t"; ok=0
    fi
  done

  # Temporary sandbox session (no long-lived credentials in a repo).
  local account
  if account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    log "AWS session OK: account ${account}, region ${region}"
  else
    log "AWS session MISSING/EXPIRED: run your sandbox login flow"; ok=0
  fi

  log "controller state root (persistent, outside repo & VM): $(controller_state_root)"
  [ -n "$env_id" ] && log "environment '${env_id}' state: $(env_state_dir "$env_id")"

  [ "$ok" = 1 ] || die "controller is NOT ready; fix the items above before provisioning."
  log "controller READY."
}

usage() {
  cat >&2 <<'TXT'
dbai console — DBAI course Terraform controller (runs on your laptop, not the VM)

Controller operations:
  console.sh doctor [--environment-id <id>] [--region <r>]   Check prerequisites/session
  console.sh select-backend --environment-id <id> [--region <r>]   Select+record backend
  console.sh init-address --environment-id <id> [--region <r>]     Allocate/reuse the EIP
  console.sh initialize --environment-id <id> --profile <name> --ssh-public-key <p> \
      [--deploy-public-key <p>] [--instructor-public-key <p>] [--ssh-private-key <p>] [--region <r>]   Create/reconnect the workspace
  console.sh plan <id>              Native Terraform plan (detailed-exitcode)
  console.sh destroy-address <id> [region]     Distinct address (EIP) cleanup
  console.sh check-keys --phase <SNN> [--student p --deploy p --instructor p]
  console.sh status <id>            Print the environment manifest
  console.sh terraform-cmd <id>     Print the exact native Terraform invocation
  console.sh unlock <id>            Release a stale workspace lock (recovery)
  console.sh help

The legacy CloudFormation + Ansible path (README.md) is separate and unchanged.
TXT
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    select-backend)  cmd_select_backend "$@" ;;
    status)          cmd_status "$@" ;;
    doctor)          cmd_doctor "$@" ;;
    init-address)    cmd_init_address "$@" ;;
    initialize)      cmd_initialize "$@" ;;
    plan)            cmd_plan "$@" ;;
    destroy-address) cmd_destroy_address "$@" ;;
    check-keys)      cmd_check_keys "$@" ;;
    terraform-cmd)   cmd_terraform_cmd "$@" ;;
    unlock)          cmd_unlock "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $sub" ;;
  esac
}

# Allow `source`ing for tests without executing a command.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
