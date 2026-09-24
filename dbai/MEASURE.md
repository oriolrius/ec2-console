# Measure the full S6 recovery and preserve its evidence (RECOVERY-07)

The S6 lab advertises a **45-minute** "rebuild and recover" block (doc-8 § Lab
block B). For that promise to be honest the measured recovery must include
**every** real bootstrap and credential step — the clock starts **before**
`terraform apply`, not after the environment is already half-prepared. This
runbook is the timed proof harness over the [RESTORE.md](./RESTORE.md) route
(RECOVERY-06) and the controller-state restore ([BACKUP.md](./BACKUP.md),
ENV-12): it defines what to time, what evidence to keep, and how an overrun or a
failed run is recorded — so the published budget is qualified before teaching.

Run it from the persistent controller. Capture every command, its artifact
revision, its timing and a **redacted** output into the recovery evidence record.

---

## 1. The timer: what starts and stops it (AC#1, AC#6)

```bash
T0=$(date +%s)          # START — BEFORE the first `terraform apply` of the rebuild
# ... the full RESTORE.md route runs here ...
T1=$(date +%s)          # STOP — only AFTER BOTH proofs below pass
echo "recovery wall-clock: $(( (T1 - T0) / 60 ))m $(( (T1 - T0) % 60 ))s"
```

- **Start (T0):** immediately before the rebuild's Terraform apply. It must
  precede all bootstrap/readiness, host verification and credential work — never
  after preparation (AC#1, AC#6).
- **Stop (T1):** only after **both** services are proven:
  1. the **pipeline-deployed** hello-world release answers with its new version
     (`curl / | jq .message,.hostname`), and
  2. the **authenticated workbench chat** returns a real completion through the
     S4 tunnel (`course-chat`, nan.builders; restored `COURSE_VIRTUAL_KEY`).
- **A failed/interrupted run is recorded as `FAILED`/`INCOMPLETE`** with the
  elapsed time so far — never as a passed recovery with preparation time omitted
  (AC#6). If the timer stopped before both proofs passed, the run did not pass.

---

## 2. Evidence checklist — every step recorded (AC#2, AC#3, AC#7)

Record each row with its command, artifact revision, timestamp and **redacted**
output. The record must be sufficient for a reader to **repeat the proof** (AC#7).

| # | Step | Evidence to capture |
|---|---|---|
| 1 | Survivors verified before destroy | `recover`/`doctor --redacted`: controller+address state, keys, external creds present |
| 2 | Bootstrap / readiness | `rebuild --evidence-synced` completes; instance reaches ready |
| 3 | Trusted host verification | `verify-host <id>` passes on the **new** host key (fingerprint recorded, RECONNECT.md) |
| 4 | Outbound GitHub credential restored | new `~/.ssh/gh_deploy.pub` registered as read-only deploy key (public key only) |
| 5 | Both clones + upstream remotes | `git -C ~/hello-world remote -v`, `git -C ~/ai-workbench remote -v` show origin+upstream |
| 6 | GHCR login | `docker login ghcr.io` succeeds (effect only; no PAT) |
| 7 | Release completion | release.yml run URL/tag; `curl /` shows the **new** version on the new hostname |
| 8 | Workbench `.env` restored | `.env` recreated from the secret store (never Git); `docker compose ps` healthy |
| 9 | Gateway chat | `course-chat` completion over the S4 tunnel (redacted body) |

### Retained-identity proof (AC#3)

The recovery must prove the **stable course-contract address survived** and the
CI/CD identity did not change:

- **Retained EIP:** `init-address` reports the EIP **reused, not allocated**; the
  new instance's `public_ip` equals the pre-loss `VM_HOST`.
- **Unchanged `VM_HOST` / `VM_SSH_KEY`:** the release pipeline deploys to the
  same host with the same inbound key (no secret rotation required to recover).
- **The four-plan sequence**, captured as evidence:
  1. **No-change adoption** — the S6 student root adopts the retained state:
     `plan` = 0 to add/change/destroy (`-detailed-exitcode` → 0).
  2. **Tag-update plan** — bumping only `HELLO_IMAGE_TAG` re-deploys the app
     without infrastructure churn.
  3. **Second no-change plan** — re-planning after the release is again 0-change
     (idempotent; the environment is settled).
  4. **Final workspace-only destruction after evidence sync** — `destroy` (or
     the workspace-only teardown) removes only workspace resources; the
     controller/address state and the EIP are retained.

---

## 3. The `ssh_command` outputs-only exercise (AC#5)

The reference homework adds an `ssh_command` **output** and re-applies. Because
an output is not a resource, this is an **outputs-only apply**: the plan shows
only *Changes to Outputs* — **0 to add/change/destroy** — so the recovered VM is
**not replaced**. The completed block lives in the instructor reference
(`dbai/terraform/examples/s6-student-root/main.tf`); the **distributed student
starter omits it**, and adding it is the graded exercise.

Verified locally (provider-agnostic proof that a new output never replaces a
resource):

```text
$ terraform plan        # after adding output "ssh_command" to an already-applied root
null_resource.vm: Refreshing state... [id=...]

Changes to Outputs:
  + ssh_command = "ssh -i <your-dbai.pem> ubuntu@203.0.113.10"

# no "Plan: N to add/change/destroy" for resources — outputs-only; the VM is only refreshed.
```

On the real S6 root the same holds: `ssh_command = "ssh -i <your-dbai.pem>
ubuntu@${module.workspace.public_ip}"` adds an output with **no** resource
replacement.

---

## 4. Budgets: supervised block and solo homework (AC#4)

Two timed runs, each checked against a **published** budget; **overruns stay
visible and trigger a documented correction before teaching** (AC#4).

| Run | Budget (doc-8) | Check |
|---|---|---|
| Supervised reference (instructor) | **45 min** — Lab block B "rebuild and recover" | full T0→T1 wall-clock ≤ 45 min |
| Solo repetition (student homework) | **≤ 90 min** consolidation (pre-class prep ≤ 30 min) | student's honest T0→T1 ≤ published homework budget |

- If a run **exceeds** its budget, the overrun is **recorded, not hidden**: note
  the elapsed time, the slow step(s), and a **documented correction** (trim the
  step, pre-stage a non-graded prerequisite, or revise the published budget)
  **before the lab is taught**. A recovery that only fits the block by starting
  the clock late is a failed qualification (AC#1/#6).

---

## 5. Student evidence / journal instructions (AC#7)

Students record, in their journal and submitted evidence:

- the exact **commands** run, in order, with the **artifact revisions**
  (repo commits, image tags, ec2-console revision);
- **timings**: T0, T1, per-phase splits, and the run's pass/fail verdict;
- **redacted outputs** for each checklist row (§2) — enough to **repeat the
  proof**, with **no secret value** (no private keys, PATs, virtual keys);
- for a failed run: the failure point, elapsed time, and the correction taken —
  recorded as `FAILED`/`INCOMPLETE`, never dressed up as a pass.

The qualification record for this task carries the same fields for the
supervised reference run.

---

## Handoff

This task qualifies the **focused S6 recovery** only; the complete
course/exam/retake rehearsal is **M11**. Once the supervised run passes within
budget and the evidence record is complete, hand off to the assessment preflight
(M11). See [RESTORE.md](./RESTORE.md) (the route), [BACKUP.md](./BACKUP.md)
(controller-state restore, ENV-12), [RECOVERY.md](./RECOVERY.md) (triage) and
[RECONNECT.md](./RECONNECT.md) (host-key trust).
