# DBAI course Terraform path

This directory adds the **DBAI course Terraform backend** to ec2-console. It is
a *separate* path from the repository's legacy CloudFormation + Ansible route
(see the top-level [`README.md`](../README.md) "Deploy" / "Tear down"), which is
unchanged and remains supported for non-course consumers.

> Terraform and CloudFormation never manage the same resources. Course
> environments start **fresh** under Terraform (doc-18 §1).

## Controller entry point

All course operations run from the controller (student laptop / macOS / WSL2),
never only from inside the VM they destroy (doc-18 §2). The entry point is
[`console.sh`](./console.sh).

### Implemented commands

| Command | Behavior |
|---|---|
| `console.sh select-backend --environment-id <id> [--region <r>]` | Validate prerequisites, run the CloudFormation-ownership guard, select the Terraform (local) backend for a **fresh** course environment, and record the selection in the controller state manifest. |
| `console.sh status <id>` | Print the recorded backend selection for an environment. |
| `console.sh help` | Show usage. |

No other subcommands exist yet. Do not reference unimplemented operations
(plan / apply / start / stop / doctor / rebuild / destroy / adopt / final
cleanup) in student-facing material — they arrive in later M01 tasks.

### Select the backend

```bash
dbai/console.sh select-backend --environment-id my-course-env --region eu-west-1
dbai/console.sh status my-course-env
```

This runs `terraform init` on `dbai/terraform/workspace` with an explicit local
backend and writes a complete **non-secret environment manifest** to the
controller state root.

### Controller state root (persistent, outside repos and the VM)

Per-student state lives outside any Git repository and outside the disposable
VM (doc-18 §2), with restricted permissions (`700`):

| Controller | State root (`<id>` = environment id) |
|---|---|
| Linux | `${XDG_STATE_HOME:-$HOME/.local/state}/ec2-console/dbai/<id>/` |
| WSL2 | same as Linux |
| macOS | `${XDG_STATE_HOME:-$HOME/Library/Application Support}/ec2-console/dbai/<id>/` |

Each environment id resolves to its **own** subdirectory, so two environments on
one controller never share state or metadata. Each directory holds:

- `environment.json` — the non-secret manifest (below).
- `workspace.tfstate` / `address.tfstate` — controller-owned Terraform state.

### Environment manifest (`environment.json`)

Records the full resource/backend/profile identity and **no secrets**:
baseline & profile version, environment id, AWS account/region, active root,
ec2-console & module revision, both backend paths (`address`, `workspace`), EIP
allocation id, instance id, allowed tags, connection outputs, and the
`bootstrap_template_sha256` (so profile drift is visible). Private keys, tokens
and credentials are never stored — `key_refs` hold controller-local **paths**
only (doc-18 §3).

`status <id>` fails clearly if the manifest is missing or its identity is
inconsistent — it never silently falls back to another environment.

### What to retain / back up

The **controller state root is the only persistent copy** of your environment
identity and Terraform state — the VM is disposable. Back up each
`ec2-console/dbai/<id>/` directory (manifest + `*.tfstate`) and your
controller-local SSH/deploy keys. Losing it means losing the ability to resume,
plan against, or cleanly destroy the environment. Nothing here ever enters Git.

## Address and workspace: two independent states

The environment has **two** independent Terraform states so a VM rebuild keeps
the same public IP (doc-18 §3):

| State | Owns | State file (controller-local) | Cleanup |
|---|---|---|---|
| **address** | exactly one persistent Elastic IP (`aws_eip`) | `…/ec2-console/dbai/<id>/address.tfstate` | `console.sh destroy-address <id>` |
| **workspace** | network, VM, association to the address (never the EIP itself) | `…/ec2-console/dbai/<id>/workspace.tfstate` | workspace destroy (later ENV task) |

```bash
dbai/console.sh init-address --environment-id <id> --region eu-west-1   # allocate/reuse the EIP
dbai/console.sh destroy-address <id> eu-west-1                          # distinct address cleanup
```

`init-address` allocates the EIP once and records its `eip_allocation_id` in the
manifest; re-running reuses the same allocation (no duplicate). The workspace
**consumes** that allocation id and owns no `aws_eip`, so a **workspace destroy
can never destroy the address** — only `destroy-address` can.

> **A retained address is billable.** After you destroy the workspace VM, the
> Elastic IP still exists (that is the point — the IP is preserved for the
> rebuild) and AWS charges for an Elastic IP that is not associated with a
> running instance. Release it with `destroy-address` at final cleanup.

## Native Terraform, one active root, and the shared lock

From S6 on, students use **both** the controller and **native Terraform**
against the *same* environment. Two rules keep those routes safe:

- **One active root.** Every operation resolves the single `active_root`
  recorded in the manifest. A request against a different (stale) root is
  **rejected, not applied**. Print the exact native invocation for the active
  root with:

  ```bash
  dbai/console.sh terraform-cmd <id>
  ```

  Run native Terraform using exactly that `terraform -chdir=… init
  -backend-config=path=…` line so it shares the backend and state.

- **A shared state lock.** The local backend locks the workspace state file
  during any mutation, so a controller operation and a native `terraform apply`
  cannot both proceed — the second fails with a clear nonzero *"Error acquiring
  the state lock"*. Controller operations additionally take an advisory lock so
  two controller runs cannot race. Never run the controller and native CLI
  concurrently against the same environment.

### Lock recovery

If a run is interrupted, the lock and its owner context remain so you can
recover without creating a second state copy. When you are sure no operation is
running:

```bash
dbai/console.sh unlock <id>          # controller advisory lock
terraform -chdir=dbai/terraform/workspace force-unlock <LOCK_ID>   # native state lock, if shown
```

> This baseline uses a **local** backend. A remote backend is **not**
> introduced silently: adopting one must preserve per-student isolation and
> locking and requires a versioned amendment (doc-18 §3).

## Legacy environments (retirement / import route)

`select-backend` refuses to attach a CloudFormation-owned environment to the
Terraform backend: if a CloudFormation stack named `<id>` exists in any state
other than `DELETE_COMPLETE`, the command **exits nonzero and modifies
nothing**. This prevents dual resource ownership (doc-18 §1).

A legacy CloudFormation environment must be handled by one of these **separate**
routes before a Terraform course environment can use that identity:

1. **Retire it.** Destroy the legacy stack with the documented legacy path, then
   provision a fresh Terraform environment:

   ```bash
   aws cloudformation delete-stack --stack-name <id> --region <r>
   aws cloudformation wait stack-delete-complete --stack-name <id> --region <r>
   ```

2. **Migrate it.** Use a separately tested `terraform import` plan (not part of
   this command; not run implicitly). Migration is out of scope for the course,
   which starts from newly provisioned Terraform environments (doc-18 §1).

Either way, use a different `--environment-id` for the course environment, or
complete retirement first.
