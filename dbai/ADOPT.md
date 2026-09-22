# S6 adoption — adopt the student Terraform root (RECOVERY-04)

In **S6** the environment the console created for you in S2 is handed to your own
reviewable coursework root (`ai-workbench/infra/`). Adoption **only ever changes
which root is active** — it is never a hidden reprovision, a backend switch, or a
copied state handover. It proceeds *only* after a native, detailed-exitcode plan
proves the two roots are equivalent (doc-18 §3–4).

## Preconditions

- The workspace is initialized (`console.sh initialize … --profile containers`)
  and its controller-owned local state exists.
- You have the student root checked out locally (`ai-workbench/infra/`), pinned to
  the same shared module and provider as the controller (see the root's
  `MODULE_PROVENANCE.md`). No professor state file is ever downloaded.

## Adopt

```bash
dbai/console.sh adopt-student-root \
  --environment-id <id> \
  --student-root /path/to/ai-workbench/infra \
  --region eu-west-1
```

The command runs an adoption **preflight** and then a native equivalence
**plan**:

1. **Preflight** (rejects before touching anything): local backend on both sides
   (no backend switch, no second state manager), a `module "workspace"` block and
   the `aws ~> 5.0` provider (identical resource addresses), and the student
   `cloud-init.yaml` **bytes** equal to the recorded profile bootstrap
   (`bootstrap_template_sha256`).
2. **Equivalence plan** in the student root, against the SAME state:
   `terraform plan -detailed-exitcode`.

## Exit-code contract

| Plan exit | Meaning | Adoption |
|---|---|---|
| **0** | no changes — the roots are equivalent | **adopt**: active root switches to the student path |
| **2** | changes pending — configuration is NOT equivalent | **reject**: active root unchanged, no state handover |
| **1** | Terraform error | **reject**: active root unchanged |

A preflight mismatch (backend, module/provider, or bootstrap bytes) is likewise a
**reject** that leaves the prior active root and its state ownership untouched.

## What changes, and what does not

On success **only the active-root path changes**. Resource IDs, the persistent
EIP allocation, the local backend/state identity and the installed public-key
contract all stay the same, and **no second copy of state** is made. Afterwards,
both controller operations (`console.sh plan …`) and the exported native commands
(`console.sh terraform-cmd …`) run in the student root under the **same** state
lock — so the console route and the native-Terraform route can never race.

## Origin / controller synchronization

The student root is versioned coursework in `ai-workbench` (origin), while the
**state, credentials and keys stay on the controller** and are never committed
(see the root's `.gitignore`). Keep the two in sync by pulling the pinned root
from origin onto the controller before adopting; adoption reads that on-disk
root, not the professor's state.

## Platforms

`adopt-student-root` is portable POSIX-ish bash (Linux, macOS and WSL2), using
only the shared advisory lock plus Terraform's own state lock. The rejection and
success paths behave identically across the three.
