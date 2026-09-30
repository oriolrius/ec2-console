# EC2 Console

A ready-to-use cloud development workstation on AWS. Spin up an Ubuntu 24.04 EC2 instance with a full graphical desktop, modern terminal tooling, and VS Code -- accessible via SSH, Chrome Remote Desktop, or a browser.

**Infrastructure** is defined in CloudFormation or, equivalently, Terraform (one command to create, one to destroy). **Provisioning** is handled by an idempotent Ansible playbook with modular, tagged task files.

> **DBAI course users:** there is a separate, Terraform-based course path under [`dbai/`](dbai/README.md) (controller CLI, phase profiles, per-student state). It is unrelated to [`terraform/`](terraform/main.tf), which is the plain Terraform equivalent of `cloudformation.yaml` used with this Ansible playbook.

[![Watch the demo](docs/demo-thumbnail.jpg)](https://youtu.be/hT7XWxzp-n0)
> **[Watch the full demo on YouTube](https://youtu.be/hT7XWxzp-n0)** -- deployment, provisioning, and usage walkthrough (click the image above)

## Access methods

| Method                          | Port        | Use case                                                                       |
| ------------------------------- | ----------- | ------------------------------------------------------------------------------ |
| **SSH**                   | 22          | Terminal access                                                                |
| **VS Code Remote SSH**    | 22          | Full IDE experience with remote file editing, debugging, and Jupyter notebooks |
| **Chrome Remote Desktop** | --          | Full XFCE graphical desktop (no inbound port -- uses Google's relay)           |
| **JupyterLab**            | 8888 / 8889 | Notebook interface (UV or Micromamba)                                          |

## Included tooling

| Tool                                              | Tag            | Purpose                                      |
| ------------------------------------------------- | -------------- | -------------------------------------------- |
| **AWS CLI v2**                              | `awscli`     | Interact with AWS services from the instance |
| **Docker CE + Compose v2**                  | `docker`     | Build and run containerized workloads        |
| **kubectl + Helm + eksctl + kind**          | `kubernetes` | K8s CLI, chart manager, EKS provisioner, local clusters |
| **UV**                                      | `uv`         | Fast Python package manager                  |
| **Micromamba**                              | `micromamba` | Conda-compatible environment manager         |
| **XFCE4 + Chrome Remote Desktop**           | `desktop`    | Graphical desktop via Google CRD             |
| **Kitty**                                   | `terminal`   | Terminal with native Nerd Font support       |
| **oh-my-posh**                              | `terminal`   | Modern shell prompt with glyphs              |
| **Zellij**                                  | `terminal`   | Terminal multiplexer                         |
| **herdr**                                   | `terminal`   | Runtime for coding agents                    |
| **Nerd Fonts**                              | `terminal`   | JetBrainsMono + Symbols fallback             |
| **VS Code**                                 | `vscode`     | Code editor with Python/Jupyter extensions   |
| **Google Chrome**                           | `browser`    | Web browser for desktop sessions             |

## Boilerplate projects

Two example projects under `/home/ubuntu/` demonstrate different Python environment approaches:

| Project                 | Path             | Manager                 | Port |
| ----------------------- | ---------------- | ----------------------- | ---- |
| JupyterLab (UV)         | `~/jupyterlab` | UV +`pyproject.toml`  | 8888 |
| JupyterLab (Micromamba) | `~/micromamba` | Micromamba +`env.yml` | 8889 |

Both include `start.sh`, a hello-world notebook, and `.vscode/settings.json` for automatic kernel selection.

## Getting started

Pick one of the two step-by-step runbooks. Both create the same machine and then provision it with the same Ansible playbook, including the Chrome Remote Desktop setup:

| Runbook | Infrastructure | Use it when |
| ------- | -------------- | ----------- |
| [docs/RUNBOOK-terraform.md](docs/RUNBOOK-terraform.md) | [`terraform/`](terraform/main.tf) | Recommended. Creates its own VPC, so it works in any account. |
| [docs/RUNBOOK-cloudformation.md](docs/RUNBOOK-cloudformation.md) | [`cloudformation.yaml`](cloudformation.yaml) | No Terraform installed. Needs a default VPC. |

## Ansible tags

The runbooks install everything. To (re)install only some components, pass tags. With Terraform the host IP is read from `terraform output`; with CloudFormation, set `JUPYTER_IP=<public-ip>` in front:

```bash
uv run ansible-playbook playbook.yml --tags "docker,desktop"
```

| Tag                       | What it provisions                                   |
| ------------------------- | ---------------------------------------------------- |
| `base`                  | System update + common packages (always runs)        |
| `awscli`                | AWS CLI v2                                           |
| `docker`                | Docker CE + Compose plugin + ubuntu group membership |
| `kubernetes`            | kubectl, Helm, eksctl, kind                          |
| `uv`                    | UV package manager                                   |
| `micromamba`            | Micromamba package manager                           |
| `desktop`               | XFCE4 desktop + Chrome Remote Desktop                |
| `terminal`              | Kitty, Nerd Fonts, oh-my-posh, Zellij, herdr         |
| `vscode`                | VS Code + Python/Jupyter extensions                  |
| `browser`               | Google Chrome                                        |
| `projects`              | All boilerplate projects                             |
| `jupyterlab-uv`         | JupyterLab UV project only                           |
| `jupyterlab-micromamba` | JupyterLab Micromamba project only                   |

The playbook is idempotent. Re-run it any time to apply updates or fix drift.

## Troubleshooting Chrome Remote Desktop

The runbooks cover the one-time setup. If the host stays offline or shows "disabled":

```bash
sudo systemctl status chrome-remote-desktop@ubuntu    # check the service
sudo systemctl stop chrome-remote-desktop@ubuntu      # clean restart
rm -rf /tmp/chrome_remote_desktop_*
sudo systemctl start chrome-remote-desktop@ubuntu
sudo reboot                                           # if still disabled
```

## Using the machine

**JupyterLab:**

```bash
# SSH in, then:
cd ~/jupyterlab && ./start.sh    # http://<public-ip>:8888
cd ~/micromamba && ./start.sh     # http://<public-ip>:8889
```

## VS Code Remote SSH

The recommended IDE workflow: install [VS Code](https://code.visualstudio.com/) locally with the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension, then connect to the instance. You get the full VS Code experience (editor, terminal, debugging, extensions, Jupyter notebooks) with all computation running on the EC2 instance.

### SSH config

**Windows** (`C:\Users\<user>\.ssh\config`):

```
Host ec2-console
    HostName <public-ip>
    User ubuntu
    IdentityFile C:\Users\<user>\.ssh\ec2-key.pem
```

Copy the key to your Windows `.ssh` folder and lock down permissions (PowerShell):

```powershell
Copy-Item ec2-key.pem C:\Users\<user>\.ssh\ec2-key.pem
icacls C:\Users\<user>\.ssh\ec2-key.pem /inheritance:r /grant:r "<user>:(R)"
```

**Linux / macOS** (`~/.ssh/config`):

```
Host ec2-console
    HostName <public-ip>
    User ubuntu
    IdentityFile ~/.ssh/ec2-key.pem
```

### Usage

1. `Ctrl+Shift+P` > **Remote-SSH: Connect to Host** > `ec2-console`
2. **File > Open Folder** > pick any project under `/home/ubuntu/`
3. Open a `.ipynb` file -- the Python kernel auto-selects from `.vscode/settings.json`

When the EC2 IP changes after a new deployment, update the `HostName` line in your SSH config. Everything else stays the same.

### VS Code extensions (installed on the instance)

From `files/vscode/extensions.txt`:

- **Python**, **Pylance**, **Python Environments**, **Python Debugger** -- language support, linting, debugging
- **Jupyter** (with keymap, renderers, cell tags, slideshow) -- notebook editing and kernel management
- **uv-toolkit** -- UV project support

**Remote - SSH** is installed on your local VS Code, not on the instance.

## Project structure

```
.
├── cloudformation.yaml                         # EC2 + security group
├── terraform/main.tf                           # Terraform equivalent (+ minimal VPC)
├── docs/RUNBOOK-terraform.md                   # Step-by-step guide: Terraform + Ansible + CRD
├── docs/RUNBOOK-cloudformation.md              # Step-by-step guide: CloudFormation + Ansible + CRD
├── dbai/                                       # Separate DBAI course path (see dbai/README.md)
├── playbook.yml                                # Main playbook (imports tasks/)
├── ansible.cfg
├── inventory.yml
├── tasks/
│   ├── base.yml                                # System packages
│   ├── awscli.yml                              # AWS CLI v2
│   ├── docker.yml                              # Docker CE + Compose
│   ├── kubernetes.yml                          # kubectl, Helm, eksctl, kind
│   ├── uv.yml                                  # UV package manager
│   ├── micromamba.yml                           # Micromamba
│   ├── desktop.yml                             # XFCE4 + Chrome Remote Desktop
│   ├── terminal.yml                            # Kitty, Nerd Fonts, oh-my-posh, Zellij, herdr
│   ├── vscode.yml                              # VS Code + extensions
│   ├── browser.yml                             # Google Chrome
│   ├── project-jupyterlab-uv.yml               # JupyterLab + UV boilerplate
│   └── project-jupyterlab-micromamba.yml        # JupyterLab + Micromamba boilerplate
├── files/
│   ├── desktop/
│   │   └── xfconf/                             # XFCE panel + power manager config
│   ├── terminal/
│   │   ├── kitty.conf                          # Kitty terminal config
│   │   ├── zellij-config.kdl                   # Zellij config
│   │   └── 10-nerd-font-symbols.conf           # Nerd Font fallback
│   ├── vscode/
│   │   ├── settings.json                       # VS Code user settings
│   │   └── extensions.txt                      # Extensions to install
│   ├── jupyterlab/                             # UV JupyterLab boilerplate
│   └── micromamba/                             # Micromamba JupyterLab boilerplate
└── .gitignore
```

## Instance types (eu-west-1, on-demand)

| Instance             | CPU               | vCPU | RAM   | $/hr    | $/month (24/7) |
| -------------------- | ----------------- | ---- | ----- | ------- | -------------- |
| **t3a.xlarge** | AMD (burstable)   | 4    | 16 GB | $0.1632 | $119.14        |
| c6a.xlarge           | AMD (fixed)       | 4    | 8 GB  | $0.1642 | $119.84        |
| t3.xlarge            | Intel (burstable) | 4    | 16 GB | $0.1824 | $133.15        |
| c6i.xlarge           | Intel (fixed)     | 4    | 8 GB  | $0.1824 | $133.15        |
| m6a.xlarge           | AMD (general)     | 4    | 16 GB | $0.1926 | $140.60        |

Prices from the AWS Pricing API (September 2026), Linux, shared tenancy. The monthly figure is 730 hours. A stopped instance costs nothing for compute, but the 25 GB gp3 disk always adds about **$2.20/month** until the machine is deleted.

Override: `terraform -chdir=terraform apply -var instance_type=c6a.xlarge` (Terraform) or add `ParameterKey=InstanceType,ParameterValue=c6a.xlarge` to `--parameters` (CloudFormation).

## Extending

Create a task file in `tasks/`, import it in `playbook.yml` with a tag. Add config files under `files/`. The playbook is the single source of truth for what gets installed.

## Notes

- The security group opens ports **22** (SSH) and **8888-8889** (JupyterLab) to `0.0.0.0/0`. Chrome Remote Desktop uses outbound connections only -- no inbound port needed. Restrict the CIDR in `terraform/main.tf` / `cloudformation.yaml` for tighter access control.
- The instance uses a **25 GB gp3** root volume. Increase `volume_size` in `terraform/main.tf` / `VolumeSize` in `cloudformation.yaml` if needed.

## License

MIT
