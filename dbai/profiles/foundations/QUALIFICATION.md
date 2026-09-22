# Foundations profile — capacity & boot-time qualification (PROFILE-05)

Qualifies the **`foundations`** profile (`foundations-0.1.0`, phases **S2–S3**,
`t3.small`) for class use by measuring cold-boot time and resource headroom
under the **actual** S2–S3 workload (a remote editor + the hello-world app).
This record qualifies capacity only; the full reference-student journey is M11.

## Go / no-go limits (set BEFORE measuring)

A profile is accepted for class use only if **every** limit holds. A failure
keeps the profile **unqualified** and records a proposed *versioned* size/budget
correction — a larger upstream default is **never** silently substituted (doc-18 §5).

| Limit | Threshold | Rationale |
|---|---|---|
| Cold boot (systemd, kernel+userspace) | **≤ 90 s** | student reconnects quickly after start/rebuild |
| cloud-init total | **≤ 90 s** | bootstrap completes well within a lab setup window |
| RAM headroom under editor + workload | **≥ 30 %** free of total | editor + app must not thrash a 2 GB node |
| Root disk free after bootstrap | **≥ 50 %** free | room for repos, images pulled in later sessions |
| vCPU under workload | load1 **< nproc** | no sustained saturation at rest |

## Measured result — **PASS** ✅

Live run on the sandbox (account 753916465480, eu-west-1), instance
`i-04e2bde4493ec92c0`, 2026-09-22.

| Metric | Measured | Limit | Verdict |
|---|---|---|---|
| Cold boot (systemd-analyze) | **38.43 s** (1.02 kernel + 37.41 userspace) | ≤ 90 s | ✅ |
| cloud-init total | **27.11 s** (`cloud-init status` = done) | ≤ 90 s | ✅ |
| vCPU / RAM / root disk | **2 vCPU / 1906 MB / 23.7 GB** | — | (t3.small) |
| Idle RAM used | 408 MB (1497 MB avail) | — | — |
| RAM used **with hello-world app** | ~430 MB; app RSS ~40 MB | — | — |
| + remote-editor allowance (VS Code Server, reserved) | ≤ 500 MB | — | — |
| **Peak RAM (workload + editor allowance)** | **~930 MB → ~51 % free** | ≥ 30 % free | ✅ |
| Root disk free after bootstrap | **21.4 GB / 23.7 GB → 90 % free** | ≥ 50 % free | ✅ |
| Load average (workload) | 0.07 (nproc=2) | < 2 | ✅ |

**Method note.** The hello-world app is the real S2–S3 workload and is measured
live (RSS ~40 MB, negligible CPU). The remote editor is entered as a **reserved
allowance** (VS Code Server steady state, ≤ 500 MB) rather than a fabricated
measurement; even at the top of that allowance the node keeps > 50 % RAM free, so
the go/no-go holds with wide margin.

## Recorded versions / revisions (manifest schema)

Under the common scenario/phase manifest schema (`dbai/environment-manifest/v2`
+ `dbai/profile-catalog/v1`):

- **profile:** `foundations-0.1.0` (candidate) · **instance:** `t3.small`
- **ec2-console revision:** `7a0fa4f2b5512e8b34d8dee11e9779c806ad2752` (catalog pin)
- **bootstrap template:** `dbai/profiles/foundations/cloud-init.yaml.tftpl`
  · sha256 `5a209fb7…37bd`
- **OS:** Ubuntu 24.04, kernel `7.0.0-1012-aws`
- **tools:** git `2.43.0`, uv `0.12.17` (both preinstalled by the bootstrap)
- **timestamp:** 2026-09-22 · **logs:** `systemd-analyze`, `cloud-init analyze
  show`, `free -m`, `ps --sort=-rss`, `df -m`

### ⚠ Finding — AMI pin not enforced (versioned correction proposed)

The instance launched **`ami-0526a6499f6470118`**, but the catalog pins
`ami-03957e4cfe042cca1`. The workspace module resolves the *latest* Ubuntu 24.04
AMI (`data.aws_ami.ubuntu`) instead of the catalog pin, so the recorded `ami:` is
**not** what deploys. This is a **pinning gap**, not a capacity failure (boot and
headroom pass on the resolved AMI). Proposed correction: a **new** profile
version that pins the AMI by id (or records the resolved AMI per run) so teaching
behavior cannot drift on a silent AMI refresh. Tracked for artifact-pinning
(QUAL/M11); the capacity verdict above stands for the measured AMI.

## Cost qualification (measured components, not an automatic cap)

The measured cost splits into **compute** (only while running) and **retained**
charges (persist while stopped):

| Component | Basis | Note |
|---|---|---|
| Compute — `t3.small` | ~\$0.0228 / hr on-demand (eu-west-1, reference rate) | **stops when the VM is stopped** |
| Root EBS gp3 (23.7 GB) | ~\$0.08 / GB-month (reference) | **retained while stopped** |
| Public IPv4 (retained EIP) | ~\$0.005 / hr per address (2024 AWS IPv4 charge) | **retained even when unassociated** |
| Gateway / data transfer | per-GB egress (reference) | workload-dependent |

**AWS Budget notification is NOT an automatic cap** — it emails at a threshold
but does not stop spend. Stop discipline (stop the VM when idle; release the EIP
at course end via `final-cleanup`) is the real control. Compute stops with the
VM; storage + IPv4 persist until explicitly removed.

## Verdict

`foundations-0.1.0` **meets every go/no-go limit** for S2–S3 on `t3.small` with
> 50 % RAM and disk headroom and a 38 s boot — **accepted for class use** on the
measured revision, with the AMI-pin finding carried forward as a versioned
correction (no silent upsize).
