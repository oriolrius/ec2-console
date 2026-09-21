# S4–S7 containers runbook

The **containers** profile (`containers-0.1.0`) prepares the same self-service
VM for **S4–S7**. Ubuntu 24.04 on `t3.medium`, it **adds Docker Engine and the
Compose plugin on top of** the foundations tools (git, uv, SSH) — nothing more.
It supplies the container **platform and access only**; your Dockerfile, Compose
file, release workflow and S6 recovery are your work and are never baked in.

## What the profile supplies vs. what you author

| Supplied by bootstrap | You create (S4–S7) |
|---|---|
| Docker Engine (`docker`), Compose plugin (`docker compose`), daemon enabled | your `Dockerfile` (S4 hello-world container) |
| foundations tools carried over: git, uv, SSH, remote-editor | your `compose.yaml` / workbench template (S5) |
| `ubuntu` user in the `docker` group (no sudo to run containers) | your release workflow / CI (S5) |
| the persistent environment identity + Elastic IP | your S6 student Terraform root edits and recovery evidence |

Docker, k3s, kubectl, eksctl/EKS/kind, Micromamba and heavy notebook defaults
that belong to the **operations** profile stay **absent** here — you add k8s
tooling only when S8 transitions you to that profile.

## Controller vs remote — the split

| Action | Where |
|---|---|
| `dbai/console.sh …`, Terraform, AWS session, keys, state | **controller** (your laptop) |
| building images, `docker compose up`, editing code, git commits | **remote VM** (over SSH / VS Code Remote SSH) |

## Transition from foundations to containers (S4)

The container platform arrives by re-initializing the **same** environment with
the containers profile. The persistent Elastic IP (from `init-address`) keeps
your public address stable across the `t3.small → t3.medium` resize, so the
environment identity is preserved.

`initialize` computes and prints the Terraform plan — including the
`t3.small → t3.medium` instance change — before it applies, so the planned VM
change is surfaced in the run output:

```bash
# controller
dbai/console.sh initialize --environment-id <id> --profile containers \
  --ssh-public-key <dbai.pub> --region eu-west-1
```

It resolves `instance_size`, `bootstrap_template` and `version` for `containers`
from [`../catalog.yaml`](../catalog.yaml) and records the applied
`profile_version` and bootstrap sha256 in the environment manifest, so profile
drift is visible. To inspect the recorded environment against AWS at any time
(ENV-07), run:

```bash
dbai/console.sh plan <id>
```

## Verify (remote)

```bash
ssh -i <dbai.pem> ubuntu@<public-ip>
# on the VM:
bash health-check.sh          # reports git/uv/ssh/docker + compose versions;
                              # asserts k8s tooling absent and no baked student work
docker run --rm hello-world   # daemon smoke test
```

Health verification **records installed versions** — it never claims an empty,
unprepared VM. If `docker info` fails right after the first boot, reconnect the
SSH session so the new `docker` group membership applies.

## Repeatability and S6 recovery

Provisioning is idempotent: re-running converges with no changes. An **S6
rebuild** recreates the VM from this same byte-identical bootstrap, restoring the
same prepared container platform (authorized keys via
[../../ACCESS.md](../../ACCESS.md)) — without restoring any student solution.
The rebuild verification records the installed Docker/Compose versions so the
recovered platform can be compared against the pre-rebuild one.
