# S8 Kubernetes transition & S9 inspection (PROFILE-04)

S8 is the one **deliberate** replacement of the container VM: it swaps the S4–S7
`containers` profile for the `operations` profile, which adds a single-node
**k3s** cluster with **pinned** kubectl and Helm on `t3.large`. After this
boundary the node is *populated* (Secrets, PVCs, workloads accumulate through
S9–S13), so a later change must **never** silently replace it. This runbook is
tool/platform scaffolding only — it ships **no** student manifests, values/auth,
dashboards, MLflow runs or retrieval releases (doc-18 §4).

## What changes at S8

| | S4–S7 `containers` | S8+ `operations` |
|---|---|---|
| instance size | `t3.medium` | **`t3.large`** |
| platform | Docker + Compose | Docker **+ k3s** (`k3s_enabled`) |
| pinned tools added | — | **k3s `v1.30.5+k3s1`**, kubectl (k3s-bundled `v1.30.5`), **Helm `v3.15.4`** |
| bootstrap template | `containers/cloud-init.yaml.tftpl` | `operations/cloud-init.yaml.tftpl` (new pinned revision) |
| student kubectl | n/a | **works without sudo** via `/etc/rancher/k3s/k3s.yaml` (mode 644) |

The new bootstrap is a **new pinned catalog revision** — the change in first-boot
configuration is what forces the one planned replacement below.

## Performing the transition (the one planned replacement)

The first-boot config changes (containers→operations bootstrap), so Terraform
plans a **VM replacement**. That is expected here — and it is surfaced as a plan
**before** it is applied, never silently:

1. **[controller]** Synchronize the student/controller root to the operations
   profile revision (the same module at the same addresses; only the profile
   inputs change). Commit it as versioned coursework.
2. **[controller]** Confirm the plan is a **replacement**, not a surprise:
   ```bash
   dbai/console.sh plan m02qual --profile operations   # shows the VM replacement + retained EIP/state
   ```
   The retained **EIP**, address state, controller state and enrolled **keys**
   are kept across the replacement (only the instance is recreated). Nothing on
   the old VM's disk survives — sync any evidence first (doc-18 §2).
3. **[controller]** Apply the planned transition:
   ```bash
   dbai/console.sh rebuild m02qual --evidence-synced   # destroy+recreate → fresh operations cloud-init
   dbai/console.sh verify-host m02qual                 # trust the NEW host key before reconnecting
   ```
   A profile change on a **live** instance is an in-place resize and does **not**
   re-run cloud-init (it is once-per-instance-id), so the S8 platform is installed
   by an actual **rebuild** — that is why the transition is a planned replacement,
   not an in-place edit.
4. **[workspace]** After boot, restore access and repos **before** any k8s work:
   ```bash
   ssh -i ~/.ssh/<key> ubuntu@<retained-eip>     # same student environment, same EIP
   git clone <your repos> ...                    # re-clone; disk did not survive
   kubectl get nodes                             # non-sudo; node Ready
   ```

## Lab — hello-world on your own cluster (S8)

The ready cluster is the **same student-owned environment** at the retained EIP.
`kubectl` works **without sudo** through the prescribed kubeconfig:

```bash
# [workspace] KUBECONFIG is preset by /etc/profile.d/dbai-kubeconfig.sh
kubectl get nodes                 # Ready
kubectl create deployment hello --image=<your ghcr hello-world>
kubectl expose deployment hello --port=8000
kubectl get pods,svc              # your own workload on your own cluster
helm version                      # pinned Helm present for S9 inspection
```

## Protecting a populated node (S8+ discipline) — AC#4

Once the node is populated, **applying a later profile/bootstrap change that would
replace it is destructive** — it erases Secrets/PVCs and breaks the cumulative
project. This must never happen silently:

- Any plan that would **replace** a populated S8+ instance must be read as a
  **destructive** action: the plan shows `-/+ destroy and then create`. **Stop**
  and treat it as data loss unless you have explicitly synced/retained the
  Secrets/PVCs and intend to rebuild.
- The retention handling is **explicit**: back up the needed Secrets/PVCs (or the
  work that produced them) to Git/your store first; only then rebuild. `rebuild`
  refuses without `--evidence-synced` precisely to block a silent destructive
  replacement.
- **Stop-only discipline** after the transition: stop the VM when idle
  (`console.sh stop`) — never destroy/replace a populated node to "reset" it.

## S9 bootstrap-edit exercise (plan → revert → no-change) — AC#5

S9 teaches *why* first-boot edits are dangerous, without changing the running
node:

1. **[controller]** Edit the operations bootstrap (e.g. add a package) and plan:
   ```bash
   dbai/console.sh plan m02qual --profile operations   # shows a REPLACEMENT plan (first-boot changed)
   ```
   Observe that the plan would **replace** the populated node — do **not** apply.
2. **[controller]** **Revert** the edit (restore the pinned bootstrap byte-for-byte).
3. **[controller]** Plan again — it must finish with a **no-change** result:
   ```bash
   dbai/console.sh plan m02qual --profile operations   # 0 to add/change/destroy → exit 0
   ```
   The running node is never touched; you have seen the replacement plan and
   safely backed out of it.

## Stop / preserve

After the transition the environment is **stop-only**: stop when idle, preserve
Secrets/PVCs and evidence, and never reset a populated node. Full exam rehearsal
and cleanup timing belong to the assessment package (M11). This profile ships
only the platform — student manifests, values/auth, dashboards, MLflow runs and
retrieval releases are the students' own later work.
