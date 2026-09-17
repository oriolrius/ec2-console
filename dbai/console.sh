#!/usr/bin/env bash
#
# dbai console — controller CLI for the DBAI course Terraform path (doc-18).
#
# This is the DBAI *entry point*. It is deliberately separate from the legacy
# root-level CloudFormation + Ansible path (README.md "Deploy"/"Tear down"),
# which is unchanged and remains the supported route for non-course consumers.
#
# Implemented operations:
#   select-backend   Select the Terraform backend for a fresh course
#                    environment and record the selection (ENV-01).
#   status           Print the recorded backend selection for an environment.
#   help             Show usage.
#
# Later M01 tasks add: initialize, plan, apply, start/stop, doctor, rebuild,
# workspace destroy, adopt-student-root, final-cleanup. Do NOT reference
# unimplemented commands in student-facing material.
set -euo pipefail

# --- locations -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}/terraform/workspace"

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

env_state_dir() { printf '%s/%s' "$(controller_state_root)" "$1"; }
manifest_path() { printf '%s/environment.json' "$(env_state_dir "$1")"; }
tfstate_path()  { printf '%s/workspace.tfstate' "$(env_state_dir "$1")"; }

# --- helpers ---------------------------------------------------------------
log()  { printf '[dbai] %s\n' "$*" >&2; }
die()  { printf '[dbai] ERROR: %s\n' "$*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

validate_prereqs() {
  require_tool terraform
  require_tool aws
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

  log "selecting Terraform (local) backend for environment '${env_id}'"
  terraform -chdir="$WORKSPACE_ROOT" init -input=false -reconfigure \
    -backend-config="path=${tfstate}" >&2

  # Record the selection (non-secret; no keys or tokens). doc-18 §3 manifest
  # is completed by ENV-02; ENV-01 records the backend selection itself.
  umask 077
  cat > "$manifest" <<JSON
{
  "schema": "dbai/environment-selection/v1",
  "environment_id": "${env_id}",
  "aws_account": "${account}",
  "aws_region": "${region}",
  "backend": "local",
  "backend_config": { "path": "${tfstate}" },
  "active_root": "dbai/terraform/workspace",
  "owner": "terraform",
  "selected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  log "backend selection recorded: ${manifest}"
}

cmd_status() {
  local env_id="${1:-}"
  [ -n "$env_id" ] || die "usage: console.sh status <environment-id>"
  local manifest
  manifest="$(manifest_path "$env_id")"
  [ -f "$manifest" ] || die "no backend selection recorded for '${env_id}'"
  cat "$manifest"
}

usage() {
  cat >&2 <<'TXT'
dbai console — DBAI course Terraform controller

Usage:
  console.sh select-backend --environment-id <id> [--region <r>]
  console.sh status <id>
  console.sh help

The legacy CloudFormation + Ansible path (README.md) is separate and unchanged.
TXT
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    select-backend) cmd_select_backend "$@" ;;
    status)         cmd_status "$@" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $sub" ;;
  esac
}

main "$@"
