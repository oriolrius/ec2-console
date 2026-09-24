# Operations profile — S8–S10 capacity & boot-time qualification (PROFILE-09)

Qualifies the **`operations`** profile (`operations-0.2.0`, phases **S8–S10**, `t3.large`)
for class use by measuring cold boot and resource headroom under the **actual** S8–S10
workloads **at the same time**, with a **real remote editor** attached. Capacity only; the
full reference-student journey is M11.

## Go / no-go limits (committed BEFORE any measurement)

| # | Limit | Threshold | Rationale |
|---|---|---|---|
| L1 | Cold boot (`systemd-analyze`, kernel+userspace) | **≤ 120 s** | first boot installs k3s + Helm |
| L2 | cloud-init total (`cloud-init analyze`) | **≤ 180 s** | platform ready within the lab setup window |
| L3 | Instance launch → k3s node `Ready` | **≤ 240 s** | students start S8 on a rebuilt VM |
| L4 | RAM available with S8+S9+S10 workloads + editor + LOAD FEST | **≥ 20 %** of total | doc-12 budget: stay under ~80 % of 8 GiB |
| L5 | Node CPU, full stack **idle** (5-min avg) | **≤ 30 %** | t3.large baseline is 30 %/vCPU: an idle course stack must not drain CPU credits |
| L6 | Stability during LOAD FEST | **0** OOMKilled/evicted pods, **0** restarts, authenticated probe stays **1** | load must not break the workbench |
| L7 | Root disk free with the full stack deployed | **≥ 30 %** | images + logs + growth |
| L8 | Worst-case PVC growth fits | used + unfilled PVC capacity (8 + 2 + 1 GiB) **≤ 90 %** of root disk | local-path PVCs live on the root disk |
| L9 | Profile health-check + non-sudo kubectl | **PASS** | S8 platform prepared |

A failed limit leaves the profile **unqualified** and records a proposed **versioned**
correction (e.g. `operations-0.3.0` with a larger size or disk). A larger upstream default is
never silently substituted.

## Measured result — **PASS** ✅ (L8 passes with a thin margin; see findings)

Live run on the sandbox (account 753916465480, eu-west-1). A **fresh** operations instance
`i-0d76d8fa167cbb9e8` (launched 2026-09-24T16:08:15Z) ran **all S8–S10 workloads at once**:
- **S8:** hello-world on k3s, 2 replicas (`ghcr.io/oriolrius/hello-world:dbai24-s8-1.1.0`);
- **S9:** the workbench chart 0.2.0 (pi-web-ui 1.0.0 + Qdrant v1.15.5, 2Gi PVC) behind Traefik basic-auth, deployed with the exact-SHA helper;
- **S10:** the monitoring stack (Prometheus 8Gi PVC, blackbox exporter, Grafana 1Gi PVC) with the authenticated probe.

It also ran a **real remote editor**: Microsoft VS Code CLI 1.139.0 `code serve-web`, driven from a browser over an SSH tunnel, with the student repo open and the Python + Pylance extensions active. The limits above were committed (87d39fa, 16:06:08Z) **before** provisioning.

| # | Metric | Measured | Limit | Verdict |
|---|---|---|---|---|
| L1 | Cold boot (`systemd-analyze`) | **61.6 s** (1.1 kernel + 60.5 userspace) | ≤ 120 s | ✅ |
| L2 | cloud-init total | **50.0 s** (`status: done`) | ≤ 180 s | ✅ |
| L3 | Launch → k3s node Ready | **65 s** (16:08:15Z → 16:09:20Z) | ≤ 240 s | ✅ |
| — | vCPU / RAM / root disk | 2 vCPU / 7816 MB / 23.7 GB (t3.large, 25 GB gp3) | — | — |
| L4 | RAM available, full stack + editor, **idle** | 5136 MB (**65.7 %**) | ≥ 20 % | ✅ |
| L4 | RAM available, **LOAD FEST** (min over 4 min: continuous `qdrant-load --queries` + 5000 authenticated UI GETs at c=8 + editor) | **4974 MB (63.6 %)** | ≥ 20 % | ✅ |
| L4 | … with the editor at its measured **peak** (Pylance active: 1510 MB vs 1089 MB during the run) | ≈ 4553 MB (**58 %**) | ≥ 20 % | ✅ |
| L5 | Node CPU, full stack idle, 5-min avg | **11.2 %** | ≤ 30 % | ✅ |
| — | Node CPU under LOAD FEST | 77 % avg (4 min), 99 % peak 1-min | (burst; see credits) | info |
| L6 | Stability during LOAD FEST | 0 OOMKilled/evicted, 0 workload restarts, 0 pods not Running, probe **min 1.0**, UI load 5000 ok / 0 failed | as stated | ✅ |
| L7 | Root disk free, full stack deployed | **58.2 %** (9904 MB used; images/layers 5582 MB) | ≥ 30 % | ✅ |
| L8 | Worst-case PVC growth | 9904 MB used + ≈11180 MB unfilled PVC capacity (8+2+1 GiB, 85 MB used) ≈ **88.8 %** of disk | ≤ 90 % | ✅ (thin) |
| L9 | Profile health-check / non-sudo kubectl | **HEALTH: PASS** | PASS | ✅ |

Per-pod memory at idle (`kubectl top`): grafana 206Mi, prometheus-server 192Mi, pi-web-ui 92Mi,
traefik 31Mi, metrics-server 31Mi, coredns 29Mi, hello-world 2×18Mi. Editor processes (VS Code
server + extension host + Pylance): **1089–1510 MB** RSS, **the largest single consumer**.
The only restart was k3s's own `helm-install-traefik` bootstrap job at first boot, not a course workload.

**CPU credits.** The instance runs in **Unlimited** credit mode and starts with a 0 credit balance.
LOAD FEST bursts drew surplus credits (max surplus balance 1.53; `CPUSurplusCreditsCharged` = 0
during the run). The idle course stack (11 %) is below the 30 % baseline, so surplus is paid back
while idle. Sustained load above baseline for many hours is billed as surplus credits: a small
cost line, not a slowdown.

**Method notes (honest).** The first load run was invalid: the S9 port-80 rule had not been
opened, so the probe read 0 and the UI load got HTTP 000. Port 80 was opened (the S9 step) and the
load phase was re-run; the table uses the valid run. During provisioning, an `unlock` was issued
while the original `initialize` was still alive. It had only a no-change apply left (0 added /
changed / destroyed) and both runs ended READY. Terraform's own state lock guards concurrent writes.

## Recorded versions / revisions

- **profile:** `operations-0.2.0` (candidate) · **instance:** `t3.large`, 25 GB gp3, credit mode unlimited
- **ec2-console:** module code = `main` 387b6a6 (manifest records 87d39fa: the limits-only commit on this branch)
- **bootstrap template:** `dbai/profiles/operations/cloud-init.yaml.tftpl` · `sha256:45df3946…70ad` (matches the catalog)
- **AMI:** `ami-00bf3d24573e7276a` (≠ catalog pin `ami-03957e4cfe042cca1`; see findings) · kernel `7.0.0-1013-aws`
- **tools:** k3s `v1.30.5+k3s1`, kubectl `v1.30.5`, Helm `v3.15.4`, Docker `29.1.3`, git `2.43.0`, uv `0.12.18`, VS Code CLI `1.139.0`, ms-python `2026.4.0`, Pylance `2026.4.1`
- **workload revisions:** ai-workbench fixture `dbai24-s10-fixture@659cc6f` (= starter-s10-v1.0.0 + reference student work), chart 0.2.0, monitoring charts 29.33.0 / 11.18.0 / grafana-community 13.2.5 (digest-pinned mirrors), hello-world `dbai24-s8-1.1.0` @ `sha256:21ed5b93…`
- **timestamps (UTC):** limits 16:06:08 · launch 16:08:15 · Ready 16:09:20 · idle window 16:20:40–16:25:40 · LOAD FEST 16:38:22–16:42:31
- **logs:** `systemd-analyze`, `cloud-init analyze show`, `kubectl get node` conditions, `health-check.sh`, `free -m`, `kubectl top`, Prometheus `node_cpu_seconds_total` / `probe_success`, `df -m`, `du` of local-path volumes, CloudWatch CPU credit metrics

### ⚠ Findings carried forward

1. **Disk margin is thin for S11+ (L8 at 88.8 %).** The S8–S10 PVC capacity alone uses almost all
   the headroom of the 25 GB root disk. S11 (MLflow) and S12 (ingestion image, candidate
   collections) add more on the same disk. Proposed versioned correction for the next profile
   revision: `operations-0.3.0` with a **30 GB** root volume (≈ +$0.44/month per student), to be
   decided by PROFILE-10/11 (S11–S13), which measure those workloads. Not substituted silently here.
2. **The remote editor dominates memory.** With Python + Pylance, VS Code uses 1.1–1.5 GB, more than
   the whole S10 monitoring stack. RAM stays > 58 % free even at the editor peak, so no change is
   needed; the S11+ qualification must include it too.
3. **AMI pin not enforced** (same as PROFILE-05/08): the module resolves the latest Ubuntu 24.04 AMI.

## Cost qualification (eu-west-1 list prices from the AWS Price List API, 2026-09-24; refresh before teaching)

| Component | Rate | Stops when the VM is stopped? |
|---|---|---|
| Compute `t3.large` | $0.0912 / h (≈ $66.6 / month 24×7; ≈ $17.8 at ~45 h/week) | **yes** |
| CPU surplus credits (Unlimited mode) | billed only for sustained load above the 30 % baseline | yes |
| Root EBS gp3 25 GB | $0.088 / GB-month ≈ $2.20 / month | **no**: retained while stopped |
| Public IPv4 (retained EIP) | $0.005 / h ≈ $3.65 / month, in use **or idle** | **no** |
| Course gateway | per-key notional prices, $5 / 30 d cap (nan.builders flat rate) | n/a |

**Stop discipline:** `dbai/console.sh stop <env-id>` outside working hours (compute stops; disk and
IPv4 keep billing). `final-cleanup <env-id> --confirm` at course end. **An AWS Budget alert only
notifies; it never stops or caps anything.**
