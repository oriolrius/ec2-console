# S2–S3 foundations runbook

The **foundations** profile (`foundations-0.1.0`) is the one self-service remote
VM where you develop in **S2** and continue in **S3**. Ubuntu 24.04 on
`t3.small` with git, uv, SSH and minimal shell/remote-editor support. It
supplies reliable **tools and access only** — never your app fixes, feature/tests
or CI (those are your work).

## Controller vs remote — the split

| Action | Where |
|---|---|
| `dbai/console.sh …`, Terraform, AWS session, keys, state | **controller** (your laptop) |
| editing code, running the app, package management (uv), git commits | **remote VM** (over SSH / VS Code Remote SSH) |

All coding after S1 — including S3 — runs in this remote workspace, not on your
laptop.

## Bring it up (controller)

```bash
dbai/console.sh doctor --region eu-west-1
dbai/console.sh select-backend --environment-id <id> --region eu-west-1
dbai/console.sh init-address  --environment-id <id> --region eu-west-1
# provision the foundations VM (initialize — ENV-06) consuming the EIP + profile
```

## Verify (remote)

```bash
ssh -i <dbai.pem> ubuntu@<public-ip>
# on the VM:
bash health-check.sh        # reports git/uv/ssh versions; asserts heavy tools absent
uv --version && git --version
```

Health verification reports installed versions — it never claims an empty,
unprepared VM. Docker, k3s, EKS/eksctl/kind, Micromamba and heavy desktop /
notebook defaults are intentionally **absent**; you add what a later phase needs.

## What you do in S2–S3

- **S2**: fix the operational failure, do the package-management exercise (uv),
  edit and run the app on the VM.
- **S3**: add the feature/tests and author your own CI.

The profile ships none of these solutions.

## Repeatability

Provisioning is idempotent: re-running converges with no changes, and a VM
rebuild restores the same prepared foundations environment (keys via
[../../ACCESS.md](../../ACCESS.md)).
