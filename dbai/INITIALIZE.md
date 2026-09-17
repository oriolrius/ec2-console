# initialize — create or reconnect a workspace (ENV-06)

`initialize` is the repeatable entry point that creates a student's first S2
workspace or resumes an already-identified environment. It never creates a
duplicate: a healthy existing environment reconnects to the same resources.

```bash
# controller (laptop):
dbai/console.sh doctor        --region eu-west-1
dbai/console.sh select-backend --environment-id <id> --region eu-west-1
dbai/console.sh init-address   --environment-id <id> --region eu-west-1
dbai/console.sh initialize     --environment-id <id> --profile foundations \
    --ssh-public-key ~/.ssh/dbai.pub --region eu-west-1
dbai/console.sh status <id>    # instance_id, module_revision, profile_version, connection
```

Add `--deploy-public-key` (from S5) and `--instructor-public-key` (from S6) as
those identities are enrolled ([ACCESS.md](./ACCESS.md)).

## What it does

1. Validates credentials, tools and the named profile (from
   `dbai/profiles/catalog.yaml`) **before** creating anything.
2. Confirms the session account matches the manifest account.
3. Applies the workspace with the profile's instance size and bootstrap,
   consuming the environment's EIP.
4. Records `instance_id`, `module_revision` and `profile_version` in the manifest.

## Reconnect (no duplication)

Re-running against a healthy environment produces a Terraform **no-changes** plan
and reconnects to the same instance and address — never a second VM or EIP.

## Resume after interruption

Resource identity is persisted in the controller-owned Terraform state. If a
provisioning run is interrupted (e.g. the VM is lost), re-running `initialize`
recreates only what is missing and reuses the existing network and **the same
Elastic IP**, converging to one consistent environment.

## Failure behavior

`initialize` fails **nonzero** and never reports "ready" when:

- a prerequisite tool or the AWS session is missing (`doctor` diagnoses these);
- the session account does not match the manifest (`account mismatch ... NOT ready`);
- the profile is unknown, or no EIP has been allocated (`init-address` first);
- the Terraform apply/boot fails — the error propagates, and no "READY" is printed.

## Reading a plan / native Terraform (S6/S8/S9)

The wrapper never replaces the Terraform learning objective — you still read
plans and run native Terraform on the controller.

```bash
dbai/console.sh plan <id>          # native plan, detailed-exitcode:
                                   #   0 = no changes, 2 = changes pending, 1 = error
dbai/console.sh terraform-cmd <id> # the exact native invocation + backend (no secrets)
# then run native Terraform yourself against the same state/lock:
terraform -chdir=dbai/terraform/workspace init -backend-config="path=<state>"
terraform -chdir=dbai/terraform/workspace plan
```

`initialize` applies the reviewed plan, then waits for **boot readiness**
(instance status checks) and, with `--ssh-private-key`, a **profile readiness**
probe (`cloud-init status --wait`). Connection outputs are reported **only after**
readiness passes. A failed Terraform apply, bootstrap or readiness check exits
nonzero and names the responsible layer (`[layer: terraform|bootstrap|readiness]`);
none is ever labelled ready.

## Offline / fixture checks

```bash
terraform -chdir=dbai/terraform/workspace validate     # interface + module wiring
dbai/console.sh initialize --environment-id x --profile nonesuch --ssh-public-key k  # -> unknown profile, nonzero
```
The designated AWS-account run records the initial and resumed instance ids in
the task evidence; the persistent EIP is unchanged across a VM replacement.
