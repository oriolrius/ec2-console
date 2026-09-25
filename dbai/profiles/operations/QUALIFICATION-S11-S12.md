# Operations profile — S11–S12 peak capacity qualification (PROFILE-11)

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

## Measured result

_Filled in after the live run; the limits above are frozen at this commit._
