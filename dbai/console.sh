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

# Region is fixed at select-backend and recorded in the manifest — the single
# source of truth. Derive it from the manifest; a supplied --region that
# disagrees is rejected, so resources are never created in one region while
# lifecycle/queries hit another (no silent cross-region split).
resolve_region() {
  local env_id="$1" requested="${2:-}" mreg
  mreg="$(manifest_field "$env_id" aws_region)"
  if [ -z "$mreg" ]; then printf '%s' "${requested:-eu-west-1}"; return 0; fi
  if [ -n "$requested" ] && [ "$requested" != "$mreg" ]; then
    die "region '${requested}' disagrees with the environment's recorded region '${mreg}'. Region is fixed at select-backend; omit --region or pass ${mreg}."
  fi
  printf '%s' "$mreg"
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
  local env_id="" reqregion=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment-id) env_id="${2:-}"; shift 2 ;;
      --region)         reqregion="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "--environment-id is required"
  validate_prereqs
  verify_manifest "$env_id"
  local region; region="$(resolve_region "$env_id" "$reqregion")"
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
  local env_id="" profile="" reqregion="" sshkey="" deploykey="" instrkey="" sshprivkey=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --environment-id)        env_id="${2:-}"; shift 2 ;;
      --profile)               profile="${2:-}"; shift 2 ;;
      --ssh-public-key)        sshkey="${2:-}"; shift 2 ;;
      --deploy-public-key)     deploykey="${2:-}"; shift 2 ;;
      --instructor-public-key) instrkey="${2:-}"; shift 2 ;;
      --ssh-private-key)       sshprivkey="${2:-}"; shift 2 ;;
      --region)                reqregion="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ]  || die "--environment-id is required"
  [ -n "$profile" ] || die "--profile is required (see dbai/profiles/catalog.yaml)"
  [ -n "$sshkey" ]  || die "--ssh-public-key is required"

  validate_prereqs
  verify_manifest "$env_id"
  local region; region="$(resolve_region "$env_id" "$reqregion")"

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

  local iid ip rev bhash
  iid="$(terraform -chdir="$WORKSPACE_ROOT" output -raw instance_id)"
  ip="$(terraform -chdir="$WORKSPACE_ROOT" output -raw public_ip)"
  rev="$(ec2_console_revision)"
  # Record the sha256 of the ACTUAL applied profile template, so the manifest's
  # drift hash matches the profile in use (not the default workspace template).
  bhash="sha256:$(sha256sum "$boot_abs" | cut -d' ' -f1)"

  # Persist resource ids + the non-secret inputs needed to plan/apply again.
  merge_manifest "$env_id" "$(printf '{"instance_id":"%s","module_revision":"%s","profile_version":"%s","bootstrap_template_sha256":"%s","connection":{"public_ip":"%s","ssh":"ssh ubuntu@%s"},"inputs":{"profile":"%s","ssh_public_key_path":"%s","deploy_public_key_path":%s,"instructor_public_key_path":%s,"instance_type":"%s","bootstrap_template_path":"%s","region":"%s"}}' \
    "$iid" "$rev" "$pver" "$bhash" "$ip" "$ip" "$profile" "$sshkey" \
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

# Read-only environment diagnostic (ENV-11). Prints identity + categorized
# prerequisite checks; --redacted emits a professor-shareable view with no
# local paths, keys, credentials or tokens. Never prints secret values.
cmd_diagnose() {
  local env_id="" redacted=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --redacted) redacted=1; shift ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh diagnose <environment-id> [--redacted]"
  verify_manifest "$env_id"

  local acct region phase pver bver mver iid alloc active
  region="$(manifest_field "$env_id" aws_region)"
  acct="$(manifest_field "$env_id" aws_account)"
  pver="$(manifest_field "$env_id" profile_version)"
  bver="$(manifest_field "$env_id" baseline_version)"
  mver="$(manifest_field "$env_id" module_revision)"
  iid="$(manifest_field "$env_id" instance_id)"
  alloc="$(manifest_field "$env_id" eip_allocation_id)"
  active="$(manifest_field "$env_id" active_root)"
  phase="${pver%%-*}"

  echo "== dbai environment diagnostic: ${env_id} =="
  echo "account:        ${acct}"
  echo "region:         ${region}"
  echo "phase/profile:  ${phase:-?} / ${pver:-none}"
  echo "versions:       baseline=${bver:-?} module=${mver:-none}"
  echo "active root:    ${active}"
  echo "instance:       ${iid:-none}"
  echo "eip:            ${alloc:-none}"
  if [ "$redacted" = 0 ]; then
    echo "backend paths:  workspace=$(tfstate_path "$env_id") address=$(address_state_path "$env_id")"
    echo "manifest:       $(manifest_path "$env_id")"
  fi

  echo "-- prerequisite checks --"
  local ok=1
  # credentials
  local sess
  if sess="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    if [ "$sess" = "$acct" ]; then echo "credentials:    OK (account ${sess})"
    else echo "credentials:    FAIL (session ${sess} != environment ${acct})"; ok=0; fi
  else echo "credentials:    FAIL (no/expired AWS session)"; ok=0; fi
  # tools
  local miss=""
  for t in terraform aws python3 ssh; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
  [ -z "$miss" ] && echo "tools:          OK" || { echo "tools:          FAIL (missing:${miss})"; ok=0; }
  # terraform state
  if [ -f "$(tfstate_path "$env_id")" ]; then echo "terraform:      OK (workspace state present)"
  else echo "terraform:      FAIL (no workspace state; not initialized)"; ok=0; fi
  # profile resolves in catalog
  if [ -n "$pver" ] && [ -n "$(profile_field "${pver%-*}" version)" ]; then echo "profile:        OK (${pver})"
  elif [ -z "$pver" ]; then echo "profile:        (not initialized)"
  else echo "profile:        FAIL (recorded ${pver} not in catalog)"; ok=0; fi
  # workspace bootstrap/readiness (instance state)
  if [ -n "$iid" ]; then
    local st; st="$(instance_state "$env_id")"
    case "$st" in
      running) echo "workspace:      OK (instance running)" ;;
      stopped) echo "workspace:      STOPPED (instance ${iid})" ;;
      ""|None|terminated) echo "workspace:      FAIL (instance ${iid} unreachable/${st:-gone})"; ok=0 ;;
      *) echo "workspace:      ${st} (instance ${iid})" ;;
    esac
  else echo "workspace:      (no instance)"; fi

  echo "-- summary --"
  [ "$ok" = 1 ] && echo "DIAGNOSIS: healthy" || { echo "DIAGNOSIS: FAILED checks above"; return 1; }
}

# The environment's current public IP (from the connection block, nested).
connection_ip() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("connection",{}).get("public_ip") or "")' \
    "$(manifest_path "$1")" 2>/dev/null
}

# Print the replacement VM's SSH host-key fingerprints from the TRUSTED AWS
# console channel (the instance's own boot log), tied to the current instance
# id. This is the anchor a student verifies against instead of blindly trusting
# the network the first time a rebuilt VM answers on the persistent IP
# (RECOVERY-05, doc-17 §3). Read-only.
cmd_host_fingerprint() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh host-fingerprint <environment-id>"
  validate_prereqs
  verify_manifest "$env_id"
  local iid region ip
  iid="$(manifest_field "$env_id" instance_id)"
  region="$(manifest_field "$env_id" aws_region)"
  ip="$(connection_ip "$env_id")"
  [ -n "$iid" ] || die "no instance recorded for '${env_id}'; nothing to verify."
  log "trusted SSH host fingerprints for instance ${iid} (region ${region}, IP ${ip:-unknown}) via the AWS console channel:"
  local out
  out="$(aws ec2 get-console-output --instance-id "$iid" --region "$region" --latest --output text 2>/dev/null)"
  [ -n "$out" ] || die "console output not available yet for ${iid} (can lag a few minutes after boot); retry."
  local fps
  fps="$(printf '%s\n' "$out" \
        | awk '/BEGIN SSH HOST KEY FINGERPRINTS/{f=1;next} /END SSH HOST KEY FINGERPRINTS/{f=0} f' \
        | sed -E 's/^.*cloud-init: //; s/^ec2: //')"
  [ -n "$fps" ] || die "no host-key fingerprint block in the console log yet for ${iid}; retry."
  printf '%s\n' "$fps"
}

# Verify the replacement host's LIVE key against the trusted console-channel key
# BEFORE touching known_hosts or reconnecting. A mismatch — or a trusted
# fingerprint that cannot be obtained — fails nonzero and changes nothing, so a
# changed host key is never silently accepted (accept-new is not a substitute).
# Records both fingerprints; never prints private key material and never weakens
# key-only access (RECOVERY-05 AC#2/#3/#5).
cmd_verify_host() {
  local env_id="" khfile="" refresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --known-hosts) khfile="${2:-}"; shift 2 ;;
      --refresh)     refresh=1; shift ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh verify-host <id> [--refresh] [--known-hosts <file>]"
  validate_prereqs
  verify_manifest "$env_id"
  local iid region ip
  iid="$(manifest_field "$env_id" instance_id)"
  region="$(manifest_field "$env_id" aws_region)"
  ip="$(connection_ip "$env_id")"
  [ -n "$iid" ] || die "no instance recorded for '${env_id}'."
  [ -n "$ip" ]  || die "no public IP recorded for '${env_id}'."

  # (1) trusted keys from the console channel -> trusted fingerprints.
  local out trusted_keys trusted_fp
  out="$(aws ec2 get-console-output --instance-id "$iid" --region "$region" --latest --output text 2>/dev/null)"
  [ -n "$out" ] || die "[reject] trusted channel unavailable: no console output for ${iid} yet; NOT verified."
  trusted_keys="$(printf '%s\n' "$out" \
        | awk '/BEGIN SSH HOST KEY KEYS/{f=1;next} /END SSH HOST KEY KEYS/{f=0} f' \
        | sed -E 's/^.*cloud-init: //; s/^ec2: //' | grep -E '^(ssh-|ecdsa-)')"
  [ -n "$trusted_keys" ] || die "[reject] no trusted host keys in the console log for ${iid} yet; NOT verified. Retry (do not bypass host checking)."
  trusted_fp="$(printf '%s\n' "$trusted_keys" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | sort -u)"

  # (2) observed keys live from the host.
  local observed observed_fp
  observed="$(ssh-keyscan -T 10 "$ip" 2>/dev/null | grep -E ' (ssh|ecdsa)')"
  [ -n "$observed" ] || die "[reject] ssh-keyscan got no key from ${ip} (host unreachable?); NOT verified."
  observed_fp="$(printf '%s\n' "$observed" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | sort -u)"

  log "trusted fingerprints (console channel, instance ${iid}):"; printf '  %s\n' $trusted_fp >&2
  log "observed fingerprints (ssh-keyscan ${ip}):";               printf '  %s\n' $observed_fp >&2

  # (3) every observed key MUST appear in the trusted set.
  local f mismatch=0
  for f in $observed_fp; do
    printf '%s\n' "$trusted_fp" | grep -qxF "$f" || { log "MISMATCH: observed ${f} is NOT in the trusted set"; mismatch=1; }
  done
  if [ "$mismatch" != 0 ]; then
    die "[reject] host key does NOT match the trusted console-channel fingerprint; refusing to touch known_hosts or reconnect. Key-only access unchanged."
  fi
  log "VERIFIED: the live host key on ${ip} matches the trusted console-channel fingerprint (instance ${iid})."

  # (4) only after verification: refresh known_hosts (remove stale IP, add verified key).
  if [ "$refresh" = 1 ]; then
    khfile="${khfile:-$HOME/.ssh/known_hosts}"
    mkdir -p "$(dirname "$khfile")"; touch "$khfile"
    ssh-keygen -R "$ip" -f "$khfile" >/dev/null 2>&1 || true
    printf '%s\n' "$observed" >> "$khfile"
    log "known_hosts refreshed (${khfile}): obsolete ${ip} entry removed, verified key added. Reconnect with StrictHostKeyChecking=yes."
  else
    log "verified only. To trust it: re-run with --refresh, or manually 'ssh-keygen -R ${ip}' then connect once to add the verified key."
  fi
}

# Rehearsed environment recovery triage (RECOVERY-08). Classifies the failure —
# expired sandbox AWS session, lost/stopped workspace, or a workspace that never
# became reachable/ready — and prints the specific route plus the retained
# state/keys it needs. It NEVER resets a repository, rewrites exam-branch history
# or provisions a clean substitute, and returns nonzero until the environment is
# healthy so a claimed recovery is never silent (doc-18 §6, §2).
cmd_recover() {
  local env_id="" redacted=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --redacted) redacted=1; shift ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh recover <environment-id> [--redacted]"
  verify_manifest "$env_id"
  local region acct iid; region="$(manifest_field "$env_id" aws_region)"
  acct="$(manifest_field "$env_id" aws_account)"; iid="$(manifest_field "$env_id" instance_id)"
  echo "== dbai recovery triage: ${env_id} =="
  echo "note: recovery preserves committed/backed-up work only; it never resets exam branches, journals or fault evidence."

  # Route 1 — expired/wrong sandbox AWS session (controller-side; no VM needed).
  local sess
  if ! sess="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || [ "$sess" != "$acct" ]; then
    echo "FAILURE: sandbox AWS session expired or wrong account (need ${acct}, have ${sess:-none})."
    echo "ROUTE (session): re-run your sandbox login to refresh temporary credentials, then 'console.sh doctor --region ${region}'."
    echo "RETAINED: controller state, address state and keys persist on the controller; no repo is reset."
    echo "recover: NOT healthy (session)."; return 2
  fi
  echo "session:      OK (account ${sess})"

  # Route 2 — lost/stopped workspace (instance state via the trusted AWS API).
  if [ -z "$iid" ]; then
    echo "FAILURE: no workspace instance recorded for '${env_id}'."
    echo "ROUTE (build): 'console.sh initialize …'. Only work committed/pushed to your repos (and GHCR) survives a VM that never existed."
    echo "recover: NOT healthy (no instance)."; return 2
  fi
  local st; st="$(instance_state "$env_id")"
  case "$st" in
    ""|None|terminated)
      echo "FAILURE: instance ${iid} is ${st:-gone} (VM lost)."
      echo "ROUTE (rebuild): sync exam branch / journal / fault evidence to Git/GHCR FIRST, then 'console.sh rebuild ${env_id} --evidence-synced'. The persistent EIP and address state are retained; uncommitted VM content does NOT survive."
      echo "recover: NOT healthy (VM lost)."; return 2 ;;
    stopped)
      echo "FAILURE: instance ${iid} is stopped."
      echo "ROUTE (start): 'console.sh start ${env_id}' preserves disk/EIP/identity, then 'console.sh verify-host ${env_id}' before reconnecting."
      echo "recover: NOT healthy (stopped)."; return 2 ;;
    running) echo "workspace:    OK (instance ${iid} running)" ;;
    *) echo "workspace:    ${st} (instance ${iid})"; echo "recover: NOT healthy (${st})."; return 2 ;;
  esac

  # Route 3 — running but unreachable / not yet ready (connectivity or bootstrap).
  local ip; ip="$(connection_ip "$env_id")"
  if [ -n "$ip" ] && ! ssh-keyscan -T 8 "$ip" >/dev/null 2>&1; then
    echo "FAILURE: instance ${iid} running but SSH is unreachable on ${ip} (lost connectivity or a bootstrap that never opened sshd)."
    echo "ROUTE (connectivity/bootstrap): check the security group and your egress; if the VM was replaced, verify the new host key with 'console.sh verify-host ${env_id}'. If the boot never completed, sync evidence then 'console.sh rebuild ${env_id} --evidence-synced'. Do not disable host checking."
    echo "recover: NOT healthy (unreachable)."; return 2
  fi
  [ -n "$ip" ] && echo "connectivity: OK (ssh port open on ${ip})"
  echo "-- recovery triage --"
  echo "recover: environment appears HEALTHY. After any replacement run 'console.sh verify-host ${env_id}' before reconnecting (RECONNECT.md). If you still cannot work, capture 'console.sh diagnose ${env_id} --redacted' for the professor and hand off to assessment preflight."
  [ "$redacted" = 1 ] && return 0
  return 0
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
  region="$(input_field "$env_id" region)"; region="${region:-$(manifest_field "$env_id" aws_region)}"; region="${region:-eu-west-1}"
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

# Current EC2 state of the environment's instance (empty if none).
instance_state() {
  local iid region; iid="$(manifest_field "$1" instance_id)"; region="$(manifest_field "$1" aws_region)"
  [ -n "$iid" ] || return 0
  aws ec2 describe-instances --instance-ids "$iid" --region "$region" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true
}

# Stop the workspace, preserving instance/disk/EIP (ENV-08). Idempotent.
cmd_stop() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh stop <environment-id>"
  validate_prereqs; verify_manifest "$env_id"
  local iid region st; iid="$(manifest_field "$env_id" instance_id)"; region="$(manifest_field "$env_id" aws_region)"
  [ -n "$iid" ] || die "no instance for '${env_id}'"
  st="$(instance_state "$env_id")"
  if [ "$st" = "stopped" ]; then log "already stopped (${iid})"; return 0; fi
  acquire_lock "$env_id" "stop"
  log "stopping ${iid} (was: ${st})..."
  aws ec2 stop-instances --instance-ids "$iid" --region "$region" >/dev/null || die "stop request failed for ${iid}"
  aws ec2 wait instance-stopped --instance-ids "$iid" --region "$region" || die "instance ${iid} did not reach 'stopped'"
  log "stopped ${iid}. Disk and EIP are retained (still billable)."
}

# Start the workspace, preserving instance/disk/EIP (ENV-08). Idempotent.
cmd_start() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh start <environment-id>"
  validate_prereqs; verify_manifest "$env_id"
  local iid region st; iid="$(manifest_field "$env_id" instance_id)"; region="$(manifest_field "$env_id" aws_region)"
  [ -n "$iid" ] || die "no instance for '${env_id}'"
  st="$(instance_state "$env_id")"
  if [ "$st" = "running" ]; then log "already running (${iid})"; return 0; fi
  acquire_lock "$env_id" "start"
  log "starting ${iid} (was: ${st})..."
  aws ec2 start-instances --instance-ids "$iid" --region "$region" >/dev/null || die "start request failed for ${iid}"
  aws ec2 wait instance-running --instance-ids "$iid" --region "$region" || die "instance ${iid} did not reach 'running'"
  log "started ${iid}."
}

# Build the workspace -var args from persisted manifest inputs (ENV-09 helpers).
_workspace_var_args() {
  local env_id="$1"; shift
  local alloc inst boot sshkey region deploykey instrkey
  alloc="$(manifest_field "$env_id" eip_allocation_id)"
  inst="$(input_field "$env_id" instance_type)"
  boot="$(input_field "$env_id" bootstrap_template_path)"
  sshkey="$(input_field "$env_id" ssh_public_key_path)"
  region="$(input_field "$env_id" region)"; region="${region:-$(manifest_field "$env_id" aws_region)}"; region="${region:-eu-west-1}"
  deploykey="$(input_field "$env_id" deploy_public_key_path)"
  instrkey="$(input_field "$env_id" instructor_public_key_path)"
  WS_ARGS=(-var "student_id=${env_id}" -var "aws_region=${region}"
    -var "ssh_public_key_path=${sshkey}" -var "eip_allocation_id=${alloc}"
    -var "instance_type=${inst}" -var "bootstrap_template_path=${boot}")
  [ -n "$deploykey" ] && WS_ARGS+=(-var "deploy_public_key_path=${deploykey}")
  [ -n "$instrkey" ]  && WS_ARGS+=(-var "instructor_public_key_path=${instrkey}")
  return 0
}

# Destroy ONLY workspace resources, preserving the address/state/controller/keys
# (ENV-09). Refuses the graded destructive drill until evidence is synced.
cmd_workspace_destroy() {
  local env_id="" evidence=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence-synced) evidence=1; shift ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh workspace-destroy <id> --evidence-synced"
  validate_prereqs; verify_manifest "$env_id"
  if [ "$evidence" = 0 ]; then
    die "refusing destructive drill: evidence-sync precondition not satisfied. Push your coursework/exam evidence to your Git repos (and GHCR) first, then re-run with --evidence-synced."
  fi
  on_managed_vm && die "run workspace-destroy from the controller, not the VM it destroys."

  local tfstate; tfstate="$(tfstate_path "$env_id")"
  terraform -chdir="$WORKSPACE_ROOT" init -input=false -reconfigure -backend-config="path=${tfstate}" >&2
  log "resources in scope for destroy (workspace only):"
  terraform -chdir="$WORKSPACE_ROOT" state list >&2 || true

  acquire_lock "$env_id" "workspace-destroy"
  local WS_ARGS; _workspace_var_args "$env_id"
  terraform -chdir="$WORKSPACE_ROOT" destroy -input=false -auto-approve "${WS_ARGS[@]}" >&2

  # Address state + EIP must remain.
  local alloc; alloc="$(manifest_field "$env_id" eip_allocation_id)"
  merge_manifest "$env_id" '{"instance_id":null,"connection":{"public_ip":null,"ssh":null}}'
  log "workspace destroyed. Preserved: EIP ${alloc}, address state, controller state and keys."
}

# Destroy then rebuild the workspace, reusing the retained address (ENV-09).
cmd_rebuild() {
  local env_id="" evidence_flag=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence-synced) evidence_flag=(--evidence-synced); shift ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh rebuild <id> --evidence-synced"
  verify_manifest "$env_id"
  local old_iid profile sshkey deploykey instrkey region
  old_iid="$(manifest_field "$env_id" instance_id)"
  profile="$(input_field "$env_id" profile)"
  sshkey="$(input_field "$env_id" ssh_public_key_path)"
  deploykey="$(input_field "$env_id" deploy_public_key_path)"
  instrkey="$(input_field "$env_id" instructor_public_key_path)"
  region="$(input_field "$env_id" region)"; region="${region:-$(manifest_field "$env_id" aws_region)}"; region="${region:-eu-west-1}"
  [ -n "$profile" ] && [ -n "$sshkey" ] || die "no persisted inputs; run initialize first"

  cmd_workspace_destroy "$env_id" ${evidence_flag[@]+"${evidence_flag[@]}"}
  release_lock  # let initialize take its own lock
  log "rebuilding workspace for '${env_id}' (old instance ${old_iid:-none})"
  local iargs=(--environment-id "$env_id" --profile "$profile" --ssh-public-key "$sshkey" --region "$region")
  [ -n "$deploykey" ] && iargs+=(--deploy-public-key "$deploykey")
  [ -n "$instrkey" ]  && iargs+=(--instructor-public-key "$instrkey")
  cmd_initialize "${iargs[@]}"
  local new_iid; new_iid="$(manifest_field "$env_id" instance_id)"
  log "rebuild complete: old instance ${old_iid:-none} -> new instance ${new_iid}"
}

# Report resources still billable for an environment (ENV-10). Returns nonzero
# if anything remains.
report_retained() {
  local env_id="$1" region; region="$(manifest_field "$env_id" aws_region)"; region="${region:-eu-west-1}"
  local insts vols eips remain=0
  insts="$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Environment,Values=${env_id}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  vols="$(aws ec2 describe-volumes --region "$region" \
    --filters "Name=tag:Environment,Values=${env_id}" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"
  eips="$(aws ec2 describe-addresses --region "$region" \
    --filters "Name=tag:Environment,Values=${env_id}" \
    --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
  echo "-- retained-resource report --"
  [ -n "$insts" ] && { echo "instances: $insts"; remain=1; } || echo "instances: none"
  [ -n "$vols" ]  && { echo "volumes:   $vols";  remain=1; } || echo "volumes:   none"
  [ -n "$eips" ]  && { echo "addresses: $eips";  remain=1; } || echo "addresses: none"
  return "$remain"
}

# Explicit final cleanup (ENV-10): workspace/storage THEN address. Separate from
# stop/workspace-destroy; requires --confirm so the address is never released by
# accident. Idempotent; reports and stays nonzero on any retained resource.
cmd_final_cleanup() {
  local env_id="" reqregion="" confirm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) confirm=1; shift ;;
      --region)  reqregion="${2:-}"; shift 2 ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh final-cleanup <id> --confirm [--region r]"
  validate_prereqs; verify_manifest "$env_id"
  [ "$confirm" = 1 ] || die "final-cleanup releases the PERSISTENT address and all workspace resources. This is not stop/workspace-destroy. Re-run with --confirm (exam environments: only after grading permits)."
  local region; region="$(resolve_region "$env_id" "$reqregion")"
  acquire_lock "$env_id" "final-cleanup"

  # Phase 1: workspace / storage.
  local tfstate; tfstate="$(tfstate_path "$env_id")"
  if [ -f "$tfstate" ]; then
    log "phase 1: workspace/storage cleanup"
    terraform -chdir="$WORKSPACE_ROOT" init -input=false -reconfigure -backend-config="path=${tfstate}" >&2
    local WS_ARGS; _workspace_var_args "$env_id"
    terraform -chdir="$WORKSPACE_ROOT" destroy -input=false -auto-approve "${WS_ARGS[@]}" >&2 || die "workspace cleanup failed; resources retained (nonzero)."
  else
    log "phase 1: no workspace state (already clean)"
  fi
  merge_manifest "$env_id" '{"instance_id":null,"connection":{"public_ip":null,"ssh":null}}'

  # Phase 2: address (after workspace).
  local addrstate; addrstate="$(address_state_path "$env_id")"
  if [ -f "$addrstate" ]; then
    log "phase 2: address cleanup"
    terraform -chdir="$ADDRESS_ROOT" init -input=false -reconfigure -backend-config="path=${addrstate}" >&2
    terraform -chdir="$ADDRESS_ROOT" destroy -input=false -auto-approve \
      -var "environment_id=${env_id}" -var "aws_region=${region}" >&2 || die "address cleanup failed; address retained (nonzero)."
  else
    log "phase 2: no address state (already clean)"
  fi
  merge_manifest "$env_id" '{"eip_allocation_id":null}'

  # Retained-resource report; nonzero until nothing billable remains.
  if report_retained "$env_id"; then
    log "final cleanup complete: no retained billable resources."
  else
    die "final cleanup incomplete: retained resources above must be accounted for."
  fi
}

# Distinct address cleanup (ENV-03). A retained address is billable; full
# ordered final cleanup is ENV-10.
cmd_destroy_address() {
  local env_id="${1:-}" reqregion="${2:-}"
  [ -n "$env_id" ] || die "usage: console.sh destroy-address <id> [region]"
  validate_prereqs
  verify_manifest "$env_id"
  local region; region="$(resolve_region "$env_id" "$reqregion")"
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

# Back up the controller state set for an environment (ENV-12): both state
# roots + the non-secret manifest, outside any repository, restricted perms.
cmd_backup() {
  local env_id="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh backup <id> [--out <path.tgz>]"
  verify_manifest "$env_id"
  local root; root="$(controller_state_root)"
  [ -z "$out" ] && out="${PWD}/dbai-backup-${env_id}-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  # Resolve to an absolute path FIRST so a relative --out can't slip a state
  # archive into the repository past the guard below.
  local outdir; outdir="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || die "backup directory does not exist: $(dirname "$out")"
  out="${outdir}/$(basename "$out")"
  case "$out" in "${SCRIPT_DIR%/dbai}"/*) die "refuse to write a backup inside the repository: ${out}";; esac
  umask 077
  # exclude the transient lock; back up manifest + both tfstate files.
  tar -czf "$out" -C "$root" --exclude='*/.dbai.lock' "$env_id"
  chmod 600 "$out" 2>/dev/null || true
  log "backup written: ${out}"
  log "ALSO back up your controller-local private keys at their recorded key_refs paths (they are NOT in this archive)."
}

# Restore controller state from a protected backup (ENV-12). Never provisions a
# replacement; reports a missing/inconsistent backup clearly.
cmd_restore() {
  local env_id="" from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      *) [ -z "$env_id" ] && { env_id="$1"; shift; } || die "unknown argument: $1" ;;
    esac
  done
  [ -n "$env_id" ] || die "usage: console.sh restore <id> --from <path.tgz>"
  [ -n "$from" ] && [ -f "$from" ] || die "backup not found: '${from}' — cannot restore (no replacement is provisioned)."
  # Verify the archive contains a matching, consistent manifest BEFORE extracting.
  local got
  got="$( { tar -xzOf "$from" "${env_id}/environment.json" 2>/dev/null || true; } | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("environment_id",""))
except Exception: print("")' 2>/dev/null || true)"
  [ "$got" = "$env_id" ] || die "backup is missing or inconsistent (no matching environment.json for '${env_id}'); refusing to restore. No replacement provisioned."

  local root; root="$(controller_state_root)"
  mkdir -p "$root"; chmod 700 "$root" 2>/dev/null || true
  tar -xzf "$from" -C "$root"
  chmod 700 "$(env_state_dir "$env_id")" 2>/dev/null || true
  verify_manifest "$env_id"
  log "restored environment '${env_id}':"
  log "  eip=$(manifest_field "$env_id" eip_allocation_id) active_root=$(manifest_field "$env_id" active_root) backend=$(manifest_field "$env_id" backend) owner=$(manifest_field "$env_id" owner)"
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
  console.sh diagnose <id> [--redacted]  Read-only environment diagnostic
  console.sh host-fingerprint <id>       Trusted SSH host fingerprints (AWS console channel)
  console.sh verify-host <id> [--refresh] [--known-hosts <f>]   Verify host key vs trusted channel
  console.sh recover <id> [--redacted]     Recovery triage: session/connectivity/bootstrap routes
  console.sh stop <id>              Stop the VM (preserve disk/EIP; still billable)
  console.sh start <id>             Start the VM
  console.sh workspace-destroy <id> --evidence-synced   Destroy workspace (keep address)
  console.sh rebuild <id> --evidence-synced             Destroy + rebuild workspace
  console.sh destroy-address <id> [region]     Distinct address (EIP) cleanup
  console.sh final-cleanup <id> --confirm      Explicit workspace THEN address teardown
  console.sh check-keys --phase <SNN> [--student p --deploy p --instructor p]
  console.sh backup <id> [--out <path.tgz>]    Back up controller state
  console.sh restore <id> --from <path.tgz>    Restore controller state
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
    diagnose)        cmd_diagnose "$@" ;;
    host-fingerprint) cmd_host_fingerprint "$@" ;;
    verify-host)     cmd_verify_host "$@" ;;
    recover)         cmd_recover "$@" ;;
    stop)            cmd_stop "$@" ;;
    workspace-destroy) cmd_workspace_destroy "$@" ;;
    rebuild)         cmd_rebuild "$@" ;;
    start)           cmd_start "$@" ;;
    destroy-address) cmd_destroy_address "$@" ;;
    final-cleanup)   cmd_final_cleanup "$@" ;;
    check-keys)      cmd_check_keys "$@" ;;
    backup)          cmd_backup "$@" ;;
    restore)         cmd_restore "$@" ;;
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
