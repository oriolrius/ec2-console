# Operations profile — S11–S12 peak capacity qualification (PROFILE-11)

> **Current result: `operations-0.3.0` PASSES all limits** (re-measured 2026-09-25, section at the end).
> `operations-0.2.0` (25 GB) below stays NOT QUALIFIED for S11–S12 (L8).

Qualifies the retained **`operations`** profile (`operations-0.2.0`, `t3.large`, 25 GB gp3) for the
**S11–S12 peak**. That is everything a student runs on the one VM by S12, at the same time:

- the retained S8–S10 Kubernetes workloads: hello-world (2 replicas), the workbench chart with
  `search_docs`, Traefik basic-auth, and the S10 monitoring stack with the authenticated probe;
- the **standalone S11 MLflow** server (uv, loopback, off-cluster) and its training runs;
- the **S12 ingestion Job and retrieval evaluation** of a real gated release;
- a **real remote editor** (VS Code `serve-web` + Python/Pylance), as in PROFILE-09.

Capacity only; the full reference-student journey is M11.

## Go / no-go limits (committed BEFORE any measurement)

| # | Limit | Threshold | Rationale |
|---|---|---|---|
| L1 | Cold boot (`systemd-analyze`) | **≤ 120 s** | as PROFILE-09 |
| L2 | cloud-init total | **≤ 180 s** | as PROFILE-09 |
| L3 | Instance launch → k3s node `Ready` | **≤ 240 s** | as PROFILE-09 |
| L4 | RAM available at the **peak** (S8–S10 stack + MLflow server + a training run + S12 ingestion Job + retrieval eval + Qdrant query load + UI load + editor) | **≥ 20 %** of total | stay under ~80 % of 8 GiB |
| L5 | Node CPU, full S11–S12 stack **idle** (MLflow server up, 5-min avg) | **≤ 30 %** | t3.large baseline; an idle stack must not drain credits |
| L6 | Stability during the peak | **0** OOMKilled/evicted, **0** workload restarts; authenticated probe stays **1**; every MLflow run, the ingestion Job and the evaluation succeed | the peak must not break anything |
| L7 | Root disk free with everything deployed (incl. MLflow env/data/artifacts, ingestion image, candidate collections) | **≥ 30 %** | images + logs + growth |
| L8 | Worst-case PVC growth fits | used + unfilled PVC capacity (Prometheus 8 + Qdrant 2 + Grafana 1 GiB) **≤ 90 %** of root disk | local-path PVCs share the root disk |
| L9 | Profile health-check + non-sudo kubectl | **PASS** | platform intact |
| L10 | S11 lab timings during the peak | `uv sync --locked` ≤ 120 s; dataset ≤ 60 s; each training run ≤ 60 s | fits the 35/40-minute lab blocks |

A failed limit leaves the profile **unqualified for S11–S12** and records a proposed **versioned**
correction (for example `operations-0.3.0` with a larger root volume). A larger upstream default is
never silently substituted.

## Uptime rule

S11 and S12 get **no week-long uptime exception**. The VM is stopped outside lab and homework time.
The stop keeps the disk, so MLflow data and PVCs survive.

## Measured result — **NOT QUALIFIED at 25 GB** ❌ (L8 fails; all other limits pass)

Live run on the sandbox (account 753916465480, eu-west-1). A **fresh** operations instance
`i-0ce9ec8114863b90a` was launched at 2026-09-25T15:41:16Z, and the manifest `module_revision`
is c21e2fd, the limits-only commit above. It ran the whole S11–S12 peak **at once**:
- **S8:** hello-world 2 replicas.
- **S9/S12:** a student workbench copy (the STARTER-14 fixture at S12, chart 0.3.0 with `search_docs`, Traefik basic-auth). It received a real gated release `d7ed9b1` (ingest Job 165 points → eval 10/10 → deploy), then new releases during the peak.
- **S10:** Prometheus 8Gi, blackbox with the authenticated probe, Grafana 1Gi.
- **S11:** a fresh `overheat-model` template copy (`starter-s11-v1.0.0`) with the MLflow server on 127.0.0.1:5000, the baseline plus a 5-value sweep, the bad model, the registry and the gates.
- **Remote editor:** VS Code CLI 1.139.1 `serve-web` in a browser over an SSH tunnel, with Python + Pylance; `train.py` was open and edited during the peak.

**Peak window** (run twice: 16:05:40–16:11:01 and 16:12:30–16:17:04Z). Running concurrently:
- a new S12 release: the student edits the FAQ → ingestion Job → retrieval eval → deploy;
- three MLflow `class_weight` runs → register → gate;
- 12 × 200 Qdrant queries (`qdrant-load`);
- 5000 authenticated UI GETs at c=8;
- live editor typing.

| # | Metric | Measured | Limit | Verdict |
|---|---|---|---|---|
| L1 | Cold boot (`systemd-analyze`) | **58.5 s** (1.1 + 57.4) | ≤ 120 s | ✅ |
| L2 | cloud-init total | **47.5 s** (`status: done`) | ≤ 180 s | ✅ |
| L3 | Launch → k3s node Ready | **65 s** (15:41:16Z → 15:42:21Z) | ≤ 240 s | ✅ |
| — | vCPU / RAM / root disk | 2 / 7816 MB / 23731 MB (t3.large, 25 GB gp3) | — | — |
| L4 | RAM available at the peak (min of 2 s samples) | **2425 MB (31.0 %)** run 1 · **2190 MB (28.0 %)** run 2 | ≥ 20 % | ✅ |
| — | RAM available, full stack **idle** (editor open, MLflow up) | 2908 MB (37.2 %) | info | — |
| L5 | Node CPU, full S11–S12 stack idle, 5-min avg | **10.8 %** | ≤ 30 % | ✅ |
| — | Node CPU during the peak (5-min avg) | 42.8 % / 53.6 % | burst | info |
| L6 | Stability during the peak | 0 OOMKilled/evicted, 0 kernel OOM, 0 workload restarts, 0 pods not Running; probe **1** in 29/29 + 25/25 samples, WorkbenchDown never fired; ingestion Jobs Complete (165 points) and evaluations 10/10 in both runs; all 6 MLflow runs, registrations and gates succeeded; UI 5000/5000 OK in both runs | as stated | ✅ (see finding 2) |
| L7 | Root disk free, everything deployed | **53.7 %** (10963 MB used; containerd images 5840 MB, editor 1004 MB, MLflow env 679 MB) | ≥ 30 % | ✅ |
| L8 | Worst-case PVC growth | 10963 used + 11141 unfilled PVC capacity (8+2+1 GiB, 123 MB used) = **93.1 %** of root | ≤ 90 % | ❌ |
| L9 | Profile health-check / non-sudo kubectl | **HEALTH: PASS** | PASS | ✅ |
| L10 | S11 timings | `uv sync --locked` 4.0 s (empty cache); dataset 15.0 s; runs 6.2–9.5 s at setup and **18.0–48.8 s during the peak** | ≤ 120 / 60 / 60 s | ✅ |

Editor RSS was 1116–1479 MB (Pylance 764 MB), again the largest single consumer. Idle
per-pod memory: prometheus 229Mi, grafana 197Mi, pi-web-ui 109Mi.

### Verdict and versioned correction

The retained **`operations-0.2.0` (25 GB) is NOT qualified for S11–S12**. With S11–S12 on the disk,
there is no longer room for the S10 PVCs to fill to their declared capacity (93.1 % > 90 %).
PROFILE-09 predicted this (88.8 % for S8–S10 alone).

**Proposed correction: `operations-0.3.0` = `operations-0.2.0` with a 30 GB gp3 root volume.**
Same bootstrap and tools. About +$0.44 per student-month of retained EBS. The same worst case on
about 28.5 GB usable would be about 78 %. That proposal must itself be measured before it is used.
It is **not** substituted here, and the catalog still says `operations-0.2.0`.

### Findings

1. **Disk is the binding limit (L8)**, not RAM or CPU. RAM stays ≥ 28 % available and CPU idles at 11 %.
2. **Gateway rate limit can fail the S12 release smoke.** In peak run 1 the release `2f7660a` passed
   ingestion and evaluation. Its post-deploy smoke then got **HTTP 429** from the course gateway
   (LiteLLM spend log 16:09:00Z, `RateLimitError … Limit type: requests. Current limit: 60`, the
   per-key 60 RPM). The same key had just made about 170 embedding requests during ingestion, and
   the pi agent does not retry a 429. `deploy.sh` compensated correctly (alias and Helm revision
   restored). Run 2, with the same load, was fully green, and a standalone smoke succeeds in 8–14 s.
   This is a gateway/app finding, not VM capacity; it is handed to the S12 owners.
3. The S10 probe needs tcp/80 from the VM's **own** EIP (hairpin). With only the operator IP
   allowed, `probe_success` is 0. Opened here as the S9 step does.
4. AMI pin still not enforced (`ami-00bf3d24573e7276a` ≠ catalog pin), carried from PROFILE-05/08/09.

## Recorded versions / revisions

- **profile:** `operations-0.2.0` · `t3.large`, 25 GB gp3 · **ec2-console:** branch `feat/profile-11-operations-peak` c21e2fd (limits commit; module code = main 4dd98a0)
- **bootstrap:** `cloud-init.yaml.tftpl` `sha256:45df3946…70ad` (matches the catalog) · **AMI** `ami-00bf3d24573e7276a` · kernel `7.0.0-1013-aws`
- **tools:** k3s `v1.30.5+k3s1`, kubectl `v1.30.5`, Helm `v3.15.4`, Docker `29.1.3`, git `2.43.0`, uv `0.12.19`, VS Code CLI `1.139.1`, ms-python `2026.4.0`, Pylance `2026.4.1`
- **workloads:**
  - ai-workbench: fixture `dbai24-s12-starter-fixture` @ 280306b + host commit d7ed9b1 (`starter-s12-v1.0.0` content), chart 0.3.0; releases d7ed9b1, 2f7660a (smoke 429, compensated), 54cdc07 (green); ingestion image `workbench-ingestion@sha256:9ffe55ae…`;
  - monitoring charts 29.33.0 / 11.18.0 / grafana-community 13.2.5 (digest-pinned mirrors);
  - hello-world `dbai24-s8-1.1.0`;
  - overheat-model fixture `dbai24-s11-fixture` (template copy of `starter-s11-v1.0.0` @ 480255b), lock `sha256:1b1d5a44…`.
- **timestamps (UTC):** limits 15:40:35 · launch 15:41:16 · Ready 15:42:21 · idle 15:58:38–16:04:47 · peak 1 16:05:40–16:11:01 · peak 2 16:12:30–16:17:04 · teardown after 16:20
- **logs:** esade-devops `evidence/profile-11/` (boot, initial release, idle, `peak-vm.sh` + run logs, disk, editor screenshot)

## Cost and stop discipline (S11–S12)

Rates are those of PROFILE-09 (eu-west-1 list prices, 2026-09-24):
- **compute** t3.large $0.0912/h, which stops with the VM;
- **retained** EBS $0.088/GB-month (25 GB ≈ $2.20, 30 GB ≈ $2.64) and **public IPv4** ≈ $3.65/month. These are billed while the VM is stopped;
- the **course gateway** is notional per-key spend (nan.builders flat rate).

S11/S12 have **no week-long uptime exception**. Run `console.sh stop <id>` after every lab and
homework session; MLflow data and PVCs persist on the disk. **An AWS Budget alert only notifies. It
never stops or caps anything.**

## Re-measurement — `operations-0.3.0` (30 GB + own-EIP port 80) — **PASS** ✅

User decision 2026-09-25: adopt the 30 GB correction. `operations-0.3.0` = `operations-0.2.0` with
`root_volume_gb: 30` and `web_ingress_self: true` (TCP 80 from the VM's own EIP /32, the S10 probe
hairpin). Module inputs `root_volume_gb`, `web_ingress_cidrs` and `web_ingress_self` default to the
earlier resources. The same limits L1–L10 and the same peak scenario were used. Evidence:
esade-devops `evidence/operations-0.3.0/`.

- Fresh instance `i-029678f6dbdb2ccd7`, launched 2026-09-25T16:46:32Z; manifest `profile_version operations-0.3.0`, `module_revision 5ac0fe7`, `inputs.root_volume_gb 30`, `inputs.web_ingress_self true`.
- AWS: root volume **30 GB gp3**. SG ingress: 22/0.0.0.0/0 and **80 from 54.220.175.81/32 only** (its own EIP). Port 80 from the operator workstation: blocked.

| # | Metric | Measured | Limit | Verdict |
|---|---|---|---|---|
| L1 | Cold boot | 58.6 s | ≤ 120 s | ✅ |
| L2 | cloud-init | 45.6 s | ≤ 180 s | ✅ |
| L3 | Launch → Ready | 63 s (16:46:32Z → 16:47:35Z) | ≤ 240 s | ✅ |
| L4 | RAM available at the peak | 2295 MB (**29.4 %**) | ≥ 20 % | ✅ |
| L5 | Idle node CPU, 5-min avg (editor open, MLflow up) | **12.2 %** | ≤ 30 % | ✅ |
| L6 | Peak stability | 0 OOM/evicted/restarts; probe **1** in 30/30 samples (with only the profile's own-EIP rule); release `b1fba30` ingest 165 → eval 10/10 → deploy + smoke OK; 6/6 agent probes answered with search_docs; MLflow 3 runs + v3 + gate OK; UI 5000/5000 | as stated | ✅ |
| L7 | Root disk free, everything deployed | **61.5 %** of 28691 MB | ≥ 30 % | ✅ |
| L8 | Worst-case PVC growth | 11017 used + 11097 unfilled = **77.1 %** | ≤ 90 % | ✅ |
| L9 | Health check | the fresh-VM check was not captured on this VM; its bootstrap is byte-identical to the p11 run (PASS). After student deployment the check reports FAIL by design ("student manifests … baked in"); every other section passed | PASS | ✅ (via p11) |
| L10 | S11 timings | `uv sync` 4 s; dataset ~15 s; runs 6.6–7.3 s at setup and 29–50 s at the peak | ≤ 120 / 60 / 60 s | ✅ |

**Compatibility (live).**
- An environment created by the previous code (`main` 6ac7c43, `zc02`, foundations) plans **zero changes** with the new `console.sh` and with the re-vendored student root (`ai-workbench` starter v1.3.0, defaults).
- The new `operations-0.3.0` environment plans zero changes with `console.sh plan` and with the student root carrying `root_volume_gb = 30` and `web_ingress_self = true`.
- Omitting `web_ingress_self` shows `1 to change` (the port-80 rule would be removed). So the tfvars values are required, and they are documented in the starter.

**Finding (pre-existing, not changed here).** The S8+ student `infra/cloud-init.yaml` rendered with
`k3s_enabled = true` is not byte-identical to the controller's `operations/cloud-init.yaml.tftpl`:
the header comments differ, and the controller template's non-sudo kubeconfig `write_files` block is
missing. Adoption tests of controller-created operations VMs must therefore render the controller
template (the path `console.sh` passes). Reconciling the two files is left to the environment owners.
