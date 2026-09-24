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

## Measured result

*(pending — filled from the live run)*
