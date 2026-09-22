# Containers profile — capacity & boot-time qualification (PROFILE-08)

Qualifies the **`containers`** profile (`containers-0.1.0`, phases **S4–S7**,
`t3.medium`) for class use by measuring cold-boot time and resource headroom
under the **actual** S4–S7 workload (a remote editor + Docker running a
container). Capacity only; the full reference-student journey is M11.

## Go / no-go limits (set BEFORE measuring)

| Limit | Threshold | Rationale |
|---|---|---|
| Cold boot (systemd, kernel+userspace) | **≤ 90 s** | first boot installs Docker; must still be lab-fast |
| cloud-init total | **≤ 90 s** | Docker + Compose install completes in the setup window |
| RAM headroom under editor + Docker workload | **≥ 30 %** free of total | editor + a running container must not thrash 4 GB |
| Root disk free after bootstrap | **≥ 50 %** free | room for images/layers pulled across S4–S7 |
| Docker usable **without sudo** | required | student drives Docker as `ubuntu` |

## Measured result — **PASS** ✅

Live run on the sandbox (account 753916465480, eu-west-1), a **fresh** instance
`i-0f46bf13656779f4b` (rebuilt so the containers cloud-init actually runs on
first boot), 2026-09-22.

| Metric | Measured | Limit | Verdict |
|---|---|---|---|
| Cold boot (systemd-analyze) | **50.59 s** (1.03 kernel + 49.56 userspace) | ≤ 90 s | ✅ |
| cloud-init total (installs Docker+Compose) | **38.58 s** (`cloud-init status` = done) | ≤ 90 s | ✅ |
| vCPU / RAM / root disk | **2 vCPU / 3832 MB / 23.7 GB** | — | (t3.medium) |
| Idle RAM used | 568 MB (3263 MB avail) | — | — |
| RAM used **with a running container** (nginx) | 626 MB (**3205 MB avail → 84 % free**) | — | — |
| + remote-editor allowance (VS Code Server, reserved) | ≤ 500 MB | — | — |
| **Peak RAM (workload + container + editor allowance)** | ~1126 MB → **~71 % free** | ≥ 30 % free | ✅ |
| Root disk free after bootstrap | **20.95 GB / 23.7 GB → 88 % free** | ≥ 50 % free | ✅ |
| Docker without sudo | **OK** (`docker ps`/`docker run hello-world` as `ubuntu`) | required | ✅ |
| Profile health-check | **HEALTH: PASS** (git, uv, docker, compose, daemon; excluded k3s/kubectl absent) | — | ✅ |

**Method note.** Docker is the real S4–S7 platform and is exercised live
(`docker run hello-world` succeeded; a running nginx container measured). The
remote editor is a reserved allowance (≤ 500 MB), not a fabricated measurement;
even with a container **and** the editor allowance the node keeps > 70 % RAM
free.

## Recorded versions / revisions (manifest schema)

- **profile:** `containers-0.1.0` (candidate) · **instance:** `t3.medium`
- **ec2-console revision (module):** `1ab2a6bf0cf6a9c476ec81b429a92d48d64cb867`
  (recorded in the live manifest)
- **bootstrap template:** `dbai/profiles/containers/cloud-init.yaml.tftpl`
  · sha256 `137bb7d5…829a`
- **OS:** Ubuntu 24.04, kernel `7.0.0-1012-aws`
- **tools (measured):** git `2.43.0`, uv `0.12.17`, **Docker `29.1.3`**,
  **Docker Compose `2.40.3`**
- **timestamp:** 2026-09-22 · **logs:** `systemd-analyze`, `cloud-init status`,
  `free -m`, `docker run`, `df -m`, `health-check.sh`

### ⚠ Findings carried forward

1. **AMI pin not enforced** — same as PROFILE-05: the module resolves the latest
   Ubuntu 24.04 AMI rather than the catalog pin. Capacity passes on the resolved
   AMI; a versioned AMI-pin correction is proposed for artifact pinning (QUAL/M11).
2. **In-place resize does not re-bootstrap** — changing the profile on a *live*
   instance (t3.small→t3.medium) is an in-place EC2 modify (same instance-id), so
   the new profile's cloud-init does **not** re-run and Docker is not installed.
   The containers platform is only correct after a **rebuild** (fresh instance).
   The measured evidence above is from such a rebuilt instance. Documented in the
   S8 runbook so a profile transition is always a planned replacement.

## Cost qualification (measured components, not an automatic cap)

| Component | Basis | Note |
|---|---|---|
| Compute — `t3.medium` | ~\$0.0456 / hr on-demand (eu-west-1, reference rate) | **stops when the VM is stopped** |
| Root EBS gp3 (23.7 GB) | ~\$0.08 / GB-month (reference) | **retained while stopped**; image layers accrue here |
| Public IPv4 (retained EIP) | ~\$0.005 / hr per address | **retained even when unassociated** |
| Gateway / data transfer | per-GB egress + image pulls | image-pull heavy in S4–S5 |

**AWS Budget notification is NOT an automatic cap.** Stop the VM when idle;
release the EIP at course end (`final-cleanup`). Compute stops with the VM;
storage + IPv4 persist until explicitly removed.

## Verdict

`containers-0.1.0` **meets every go/no-go limit** for S4–S7 on `t3.medium` with
> 70 % RAM and 88 % disk headroom, a 50 s first boot, and sudo-less Docker —
**accepted for class use** on the measured revision, with the AMI-pin and
re-bootstrap findings carried forward (no silent upsize).
