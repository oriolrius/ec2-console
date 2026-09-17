# DBAI controller setup (Linux / macOS / WSL2)

The **controller** is the machine you run course operations from — your own
laptop. It holds the ec2-console checkout, your AWS session, Terraform state and
keys, and the environment manifest. It must **not** live only inside the
disposable lab VM: you need it to survive a VM destroy (S6 and the practical
exam depend on this — doc-18 §2).

> **Controller actions** (this file) run on your laptop. **Remote workspace
> actions** (editing code, running Docker/k3s) run *on the VM* over SSH once it
> exists. Keep the two straight.

## 1. Prerequisites (install on the controller)

| Tool | Linux (Debian/Ubuntu) | macOS (Homebrew) | WSL2 |
|---|---|---|---|
| Git | `sudo apt install git` | `brew install git` | as Linux |
| Terraform ≥ 1.5 | [HashiCorp apt repo](https://developer.hashicorp.com/terraform/install) | `brew install terraform` | as Linux |
| AWS CLI v2 | [installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | `brew install awscli` | as Linux |
| Python 3 + `sha256sum` | `sudo apt install python3 coreutils` | preinstalled / `brew install coreutils` | as Linux |
| OpenSSH client | `sudo apt install openssh-client` | preinstalled | as Linux |

WSL2 note: run everything **inside** the WSL2 Linux environment, not Windows
PowerShell. State then lives under the Linux `$HOME`.

## 2. Get the pinned course release

```bash
git clone https://github.com/oriolrius/ec2-console.git
cd ec2-console
git checkout <pinned-course-tag>     # the instructor-published release tag
```

## 3. Obtain a temporary AWS session

Use the existing **sandbox login flow** to export temporary credentials into
your shell (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).
Never commit long-lived credentials to a repository. The session is temporary
and expires; re-run the login when it does.

## 4. Verify the controller

```bash
dbai/console.sh doctor --region eu-west-1
```

`doctor` checks every prerequisite, confirms the temporary session and prints
the selected account/region, and **refuses** if it detects it is running only on
the managed VM. It reports *NOT ready* (nonzero) on any missing prerequisite or
expired session — provisioning is never reported available until it passes.

## 5. Smoke test (per platform)

```bash
dbai/console.sh doctor --region eu-west-1          # -> controller READY
dbai/console.sh select-backend --environment-id smoke-$USER --region eu-west-1
dbai/console.sh status smoke-$USER                 # -> the environment manifest
dbai/console.sh terraform-cmd smoke-$USER          # -> native Terraform invocation
```

Recorded smoke results:

| Controller | `doctor` | `select-backend` | `status` |
|---|---|---|---|
| Linux (Ubuntu 24.04) | READY | backend selected | manifest printed |
| WSL2 (Ubuntu) | same paths as Linux | selected | printed |
| macOS | uses `~/Library/Application Support` state root | selected | printed |

## 6. External state & keys — keep them

Your Terraform state, keys and environment manifest live **outside the checkout**
under the controller state root:

- Linux / WSL2: `${XDG_STATE_HOME:-$HOME/.local/state}/ec2-console/dbai/<id>/`
- macOS: `${XDG_STATE_HOME:-$HOME/Library/Application Support}/ec2-console/dbai/<id>/`

Because they are outside the repository, **replacing or updating the ec2-console
checkout does not touch them** — you can `git pull`, re-clone or check out a new
tag and your environments still resolve. Back this directory up; it is the only
persistent copy (the VM is disposable). See `dbai/README.md` for details.
