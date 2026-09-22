# DBAI phase profiles

A **profile** freezes exactly which module, bootstrap, platform and tools
prepared an environment (doc-18 §5), so teaching and exam behavior cannot drift
through implicit upgrades. The catalog is [`catalog.yaml`](./catalog.yaml),
validated by [`validate-profiles.py`](./validate-profiles.py).

Profiles are **frozen before teaching/exams**. A changed tool/module/bootstrap
input requires a **new profile version** — never edit a published one. Capacity
and boot-time qualification happen in PROFILE-05/06/08/09/10/11; `foundations`
and `containers` are **qualified live** (see their `QUALIFICATION.md`), the
others remain pending.

## Catalog

| Profile | Phases | Instance | Adds over previous | Qualified by |
|---|---|---|---|---|
| `foundations-0.1.0` | S2–S3 | t3.small | SSH, git, uv, remote-editor, minimal shell | PROFILE-05 ✅ [evidence](./foundations/QUALIFICATION.md) |
| `containers-0.1.0` | S4–S7 | t3.medium | Docker / Compose | PROFILE-08 ✅ [evidence](./containers/QUALIFICATION.md) |
| `operations-0.2.0` | S8–S13 | t3.large | **k3s + kubectl + Helm** (S8 transition, PROFILE-04) — [runbook](./operations/RUNBOOK.md) | PROFILE-09 (capacity pending) |
| `exam-s7-practical-0.1.0` | S7 | t3.medium | *(none — reuses foundations+containers pins)* | PROFILE-06 — [preflight](../exam-preflight.sh) |
| `exam-s14-practical-0.1.0` | S14 | t3.large | *(none — reuses operations pins)* | PROFILE-10 |

**Remote development onboarding** (SSH + VS Code Remote SSH, execution-context
labels): [`foundations/REMOTE_DEV.md`](./foundations/REMOTE_DEV.md) (PROFILE-07).
The **S8 Kubernetes transition** (one planned replacement, populated-node
protection, S9 plan→revert) is [`operations/RUNBOOK.md`](./operations/RUNBOOK.md)
(PROFILE-04).

Each profile records the Ubuntu/AMI, tool pins, `ec2_console_version`,
`module_revision` (pending RECOVERY-01), `bootstrap_sha256`, `instance_size` and
the qualifying evidence task. Practical-exam profiles add **no new tools** and
never resolve through a mutable reference.

## Student-owned work excluded from each profile

| Profile | Intentionally NOT supplied |
|---|---|
| foundations | App repairs, feature/test solution, student-authored CI |
| containers | Student Dockerfile/Compose work, release workflow, S6 edits and recovery evidence |
| operations | Student manifests/values/auth, monitoring dashboard, MLflow runs, retrieval releases |
| exam-s7-practical | No pre-solved faults, no replacement grading repo |
| exam-s14-practical | No hidden automatic repair or fresh substitute project |

## Where the pins map

The catalog's `ec2_console_version`, each profile `version` and `bootstrap_sha256`
are mirrored as `phase_profile` records in the course artifact inventory
(`contracts/course-artifacts.yaml` in the course repo) and are the
`profile_version` recorded in each environment manifest (`environment.json`,
doc-18 §3). Changing a pin ⇒ new profile version ⇒ new inventory entry.

```bash
python3 dbai/profiles/validate-profiles.py --selftest
python3 dbai/profiles/validate-profiles.py dbai/profiles/catalog.yaml
```
