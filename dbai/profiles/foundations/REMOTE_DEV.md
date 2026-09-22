# Remote development onboarding — SSH & VS Code Remote SSH (PROFILE-07)

The minimum supported way to develop on your workspace is **SSH** plus **VS Code
Remote SSH**. A graphical desktop, Jupyter or other heavy services are **not**
required and are **not** enabled by default (doc-18 §2). This runbook gets you
connected from any supported controller platform and — critically — keeps
**controller** commands (your laptop: AWS, Terraform, `console.sh`) separate from
**workspace** commands (the VM: the app, its process, its socket).

## Command context labels

Every command below is tagged with **where it runs**. Never mix them up: running
an app command on your laptop, or `terraform`/`aws` on the VM, is the most common
onboarding mistake.

| Tag | Runs on | Examples |
|---|---|---|
| **[controller]** | your laptop / the controller | `aws`, `terraform`, `dbai/console.sh`, `ssh`, generating keys |
| **[workspace]** | the VM, over SSH | running the app, `curl localhost`, `ss`, `git`, `uv` |
| **[browser]** | your laptop's browser | opening a tunnelled `http://localhost:PORT` |

## 1. Connect over plain SSH (all platforms)

Your public key was installed at provisioning; connect with the matching private
key. The workspace address is the retained EIP.

- **[controller] Linux / macOS / WSL2** (identical command on all three):
  ```bash
  ssh -i ~/.ssh/<your-dbai-key> ubuntu@<workspace-eip>
  ```
  On **WSL2**, run this from the WSL shell (not PowerShell) so it uses the WSL
  key and agent. On **macOS/Linux** it is the same line. First connection prints
  the host key fingerprint — verify it against the value from
  `dbai/console.sh verify-host <id>` before typing `yes` (never disable host
  checking).

## 2. Connect with VS Code Remote SSH (all platforms)

1. **[controller]** Install the **Remote - SSH** extension in VS Code.
2. **[controller]** Add a host entry to `~/.ssh/config` (WSL2: the config inside
   WSL), so the same alias works on every platform:
   ```sshconfig
   Host dbai-workspace
     HostName <workspace-eip>
     User ubuntu
     IdentityFile ~/.ssh/<your-dbai-key>
   ```
3. **[controller]** *Remote-SSH: Connect to Host…* → `dbai-workspace`. VS Code
   installs its remote server on the VM and opens a window whose integrated
   terminal and files are **[workspace]** — everything you run there is on the VM.

On **WSL2**, launch VS Code from the WSL shell (`code .`) so Remote SSH uses the
WSL SSH stack. The connection targets the **same** workspace as plain SSH.

## 3. Reference exercise — edit and run the app *on the VM*

This proves your remote loop end to end. **AWS/Terraform/`console.sh` stay on the
laptop; the app only ever runs on the VM.**

1. **[workspace]** Confirm the preinstalled toolchain (foundations ships them):
   ```bash
   git --version && uv --version        # both present; you do NOT install them
   ```
2. **[workspace]** Clone your app repo and run it (foreground):
   ```bash
   git clone <your-hello-world-repo> ~/hello-world && cd ~/hello-world
   uv run hello-world                   # serves on :8000, stays in the foreground
   ```
3. **[workspace]** In a second SSH/Remote-SSH terminal, verify the **process and
   socket are on the VM**:
   ```bash
   ss -ltnp | grep :8000                # the listening socket exists here
   curl -s localhost:8000/health        # {"status":"ok"} — served by the VM
   ```
4. **[controller]** Meanwhile your laptop still owns the infra commands, e.g.
   `dbai/console.sh doctor <id>` — these never move to the VM.

## 4. The explicit foreground stop (S2 discipline)

S2 requires you to prove the process **died**, and the only trusted proof is the
**socket disappearing** — not the editor UI.

- **[workspace]** In the terminal running the app, press **Ctrl-C**. The
  foreground process exits.
- **[workspace]** Confirm it is gone:
  ```bash
  ss -ltnp | grep :8000 || echo "socket gone — process is really stopped"
  ```
- **Do NOT** treat *closing the VS Code window / dropping the SSH session* as the
  stop. Remote SSH can leave the process running or auto-reconnect, so a closed
  IDE is **not** evidence the process died. Only the disappeared `:8000` socket is.

## 5. Diagnose a failed connection (no heavy services)

If SSH or Remote SSH will not connect, diagnose with the **[controller]**
tooling — do **not** "fix" it by enabling a desktop, Jupyter or a notebook
server (none of those is the minimum profile, and they inflate the budget):

- **[controller]** `dbai/console.sh doctor <id> --redacted` — reports session,
  instance and connectivity status.
- **[controller]** `dbai/console.sh verify-host <id>` — confirms/records the host
  key if the VM was replaced.
- **[controller]** Missing a Remote-SSH prerequisite? Install the **VS Code
  extension** (client side) — that is the only remote-editor dependency; the VM
  needs nothing extra. A connection timeout is a security-group/egress or
  address issue, surfaced by `doctor`, not a reason to widen the profile.

## Walkthrough evidence to record

Capture, in your journal, a walkthrough that covers **both** connection routes
(plain SSH and Remote SSH) reaching the **same** workspace, and the foreground
Ctrl-C stop with the socket disappearing — **without** pre-solving the app
exercise (paste the commands and their real output, not a finished solution).
Every recorded command must carry its **[controller]/[workspace]/[browser]**
label.
