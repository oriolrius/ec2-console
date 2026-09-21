# Backup and restore controller state (ENV-12)

The controller state root is the **only** persistent copy of your environment
identity and Terraform state — the VM is disposable. Back it up.

```bash
dbai/console.sh backup  <id> --out ~/backups/<id>.tgz     # both state roots + manifest
dbai/console.sh restore <id> --from ~/backups/<id>.tgz    # recover on a supported controller
```

## What the backup set contains

- `environment.json` — the non-secret manifest (identity, versions, backend
  paths, EIP allocation, resource ids).
- `workspace.tfstate` and `address.tfstate` — both Terraform state roots.

It is written **outside any repository** with `600` permissions. The command
**refuses** to write inside the ec2-console checkout.

**Also back up your private keys.** The archive holds no private keys — only the
`key_refs` *paths*. Separately back up the controller-local SSH/deploy private
keys at those paths, protected (e.g. `chmod 600`).

## Platform paths

State lives under the controller state root (see [SETUP.md](./SETUP.md)):
`~/.local/state/ec2-console/dbai/<id>/` (Linux/WSL2) or
`~/Library/Application Support/ec2-console/dbai/<id>/` (macOS).

## Restore behavior

`restore` verifies the archive contains a **matching, consistent**
`environment.json` before extracting. A missing or inconsistent backup is
reported as a missing prerequisite and **no replacement environment is
provisioned**. After a good restore, the same identity, EIP allocation, active
root and backend ownership are recovered, and you can immediately
`dbai/console.sh plan <id>` / `diagnose <id>` the existing environment — no
state is copied into a second, competing manager.

## Single owner, one active root

Keep **one** active root and one owner of the state. After an interruption or a
restore, do not run a second controller or native Terraform against the same
state concurrently — the shared lock enforces this (see the README "shared
lock"). Renew your temporary AWS session (sandbox login) after a restore before
running AWS operations.

## Evidence

- Successful restore: identity + EIP + active root + backend recovered; a
  subsequent `plan` reports no changes.
- Failed restore: missing file, or an archive whose `environment.json` id does
  not match — reported clearly, nothing provisioned, existing state untouched.
