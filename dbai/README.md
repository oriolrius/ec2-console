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
backend and writes a non-secret selection manifest to the controller state
root (outside any Git repository):

- Linux / WSL2: `${XDG_STATE_HOME:-$HOME/.local/state}/ec2-console/dbai/<id>/`
- macOS: `${XDG_STATE_HOME:-$HOME/Library/Application Support}/ec2-console/dbai/<id>/`

State, private keys and credentials never enter Git (doc-18 §2–§3).

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
