# Environment recovery (RECOVERY-08)

A lost SSH connection, an expired sandbox AWS session, or a workspace that never
came up must each have a **rehearsed** route that preserves your work under
assessment. Recovery runs from the **persistent controller** and **never**
silently resets your repository, rewrites exam-branch history, or spins up a
clean substitute project.

Start every recovery with the triage:

```bash
dbai/console.sh recover <id>          # classifies the failure, prints the route, exits nonzero until healthy
dbai/console.sh recover <id> --redacted   # professor-safe view (no local paths)
```

`recover` returns **nonzero until the environment is verified healthy**, so a
half-finished recovery is never reported as done.

## The three routes

### 1. Expired sandbox AWS session
`recover` / `doctor` report `session … FAIL`. Nothing on the VM or in your repos
is affected — only your temporary credentials lapsed.
- **Route:** re-run your sandbox login to refresh `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`, then `dbai/console.sh doctor`.
- **Retained:** controller state, address state and keys persist on the
  controller. No repository is touched.

### 2. Lost workspace connectivity
The instance is `running` but SSH does not answer, or it is `stopped`.
- **Stopped:** `dbai/console.sh start <id>` (preserves disk, EIP and identity),
  then `dbai/console.sh verify-host <id>` before reconnecting.
- **Running but unreachable:** check the security group and your egress. If the
  VM was **replaced**, the host key changed — verify it via the trusted channel
  (`verify-host`, see [RECONNECT.md](./RECONNECT.md)); never disable host
  checking.

### 3. Failed bootstrap / lost VM
The instance is gone/terminated, or booted but never became ready.
- **Route:** **sync your exam branch, journal and fault evidence to Git/GHCR
  first**, then `dbai/console.sh rebuild <id> --evidence-synced`. The persistent
  EIP and address state are retained across the rebuild.
- **What does not survive:** anything only on the VM's disk. Only work you
  committed/pushed to your repos (and images pushed to GHCR) survives a lost VM
  (doc-18 §2). `rebuild` refuses without `--evidence-synced` precisely so a
  destructive recovery cannot erase un-synced evidence.

## Evidence and exam safety

- Recovery **never** resets exam branches or erases fault evidence
  automatically. Where coursework is still reachable, push it before any
  destructive step.
- Injected/graded failures produce professor-safe diagnostics
  (`recover --redacted`, `diagnose --redacted`) and **explicit nonzero** results
  until recovery is verified — an unrecovered environment never reports success.
- Data that cannot survive an already-lost VM (uncommitted edits, un-pushed
  images, local-only journal entries) is lost unless it was previously
  committed/backed up. Record that gap honestly in your evidence.

## Handoff to assessment

Once `recover <id>` exits `0` and `verify-host <id>` passes, capture
`diagnose <id> --redacted` as the recovery evidence and hand off to the
assessment preflight (M11) before resuming exam work. Controller metadata/state
itself is recovered from a protected backup via
[BACKUP.md](./BACKUP.md) (`console.sh restore`).

When the VM itself was lost and both course applications must be brought back
onto the replacement instance, follow the ordered application-restoration route
in [RESTORE.md](./RESTORE.md) (RECOVERY-06): renew the VM's outbound GitHub key,
clone both repos, verify the committed registry Compose, release the next
hello-world version through the S5 pipeline, and restore the workbench stack with
a course-key gateway chat — with no unversioned manual fallback.
