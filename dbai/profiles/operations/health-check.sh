#!/usr/bin/env bash
#
# Operations profile health verification (PROFILE-04). Runs ON the VM. Proves the
# S8 platform is PREPARED (pinned k3s + kubectl + Helm, non-sudo kubectl), and
# that NO student manifests/values/dashboards/MLflow/retrieval work was baked in.
set -u
fail=0

echo "== dbai operations health =="
echo "profile marker: $(cat /etc/dbai-profile 2>/dev/null || echo MISSING)"
echo "platform pins:"; sed 's/^/  /' /etc/dbai-platform-pins 2>/dev/null || echo "  MISSING"

present() { # tool
  if command -v "$1" >/dev/null 2>&1; then
    printf 'OK   %-8s %s\n' "$1" "$($1 --version 2>&1 | head -1)"
  else
    printf 'FAIL %-8s missing (profile not prepared)\n' "$1"; fail=1
  fi
}

present_v() { # tool version-cmd...
  local t="$1"; shift
  if command -v "$t" >/dev/null 2>&1; then
    printf 'OK   %-8s %s\n' "$t" "$("$@" 2>&1 | head -1)"
  else
    printf 'FAIL %-8s missing (profile not prepared)\n' "$t"; fail=1
  fi
}

echo "-- required (carried tools + S8 platform) --"
present git
present uv
present docker
present_v kubectl kubectl version --client
present_v helm helm version --short

echo "-- k3s node ready --"
if kubectl get nodes >/dev/null 2>&1; then
  echo "OK   node: $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1" "$2}')"
else
  echo "FAIL kubectl cannot reach the node (k3s down, or kubeconfig not readable)"; fail=1
fi

echo "-- kubectl works WITHOUT sudo (student access) --"
if [ "$(id -u)" -ne 0 ] && KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl version >/dev/null 2>&1; then
  echo "OK   non-root kubectl reaches the API via the prescribed kubeconfig"
else
  echo "FAIL non-root kubectl access not working"; fail=1
fi

echo "-- no baked student work (manifests/values/auth/dashboards/mlflow/retrieval) --"
if ls "$HOME"/*.yaml "$HOME"/*/*.yaml >/dev/null 2>&1 \
   || [ -e "$HOME/values.yaml" ] || [ -e "$HOME/manifests" ] \
   || kubectl get deploy -A 2>/dev/null | grep -qiE 'grafana|prometheus|mlflow|qdrant|retriev'; then
  echo "FAIL student manifests/values or a dashboard/MLflow/retrieval release appears baked in"; fail=1
else
  echo "OK   only the empty k3s platform — no student manifests/values/auth or app releases baked in"
fi

[ "$fail" = 0 ] && echo "HEALTH: PASS" || echo "HEALTH: FAIL"
exit "$fail"
