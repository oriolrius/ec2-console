# EC2 Console

A ready-to-use cloud development workstation on AWS. Spin up an Ubuntu 24.04 EC2 instance with a full graphical desktop, modern terminal tooling, and browser-based IDE -- accessible via SSH, RDP, or web browser.

**Infrastructure** is defined in CloudFormation (one command to create, one to destroy). **Provisioning** is handled by an idempotent Ansible playbook with modular, tagged task files.

## Access methods

| Method | Port | Use case |
|---|---|---|
| **SSH** | 22 | Terminal access, VS Code Remote SSH |
| **RDP** (xrdp) | 3389 | Full XFCE graphical desktop from any RDP client |
| **code-server** | 8080 | VS Code in the browser -- zero install, works from tablets |
| **JupyterLab** | 8888 / 8889 | Notebook interface (UV or Micromamba) |

## Included tooling

| Tool | Tag | Purpose |
|---|---|---|
| **AWS CLI v2** | `awscli` | Interact with AWS services from the instance |
| **Docker CE + Compose v2** | `docker` | Build and run containerized workloads |
| **UV** | `uv` | Fast Python package manager |
| **Micromamba** | `micromamba` | Conda-compatible environment manager |
| **XFCE4 + xrdp** | `desktop` | Graphical desktop accessible via RDP |
| **Kitty** | `terminal` | GPU-accelerated terminal with Nerd Font support |
| **oh-my-posh** | `terminal` | Modern shell prompt with glyphs |
| **Zellij** | `terminal` | Terminal multiplexer |
| **Nerd Fonts** | `terminal` | JetBrainsMono + Symbols fallback |
| **Chromium** | `browser` | Web browser for desktop sessions |
| **code-server** | `code-server` | VS Code in the browser |

## Boilerplate projects

Two example projects under `/home/ubuntu/` demonstrate different Python environment approaches:

| Project | Path | Manager | Port |
|---|---|---|---|
| JupyterLab (UV) | `~/jupyterlab` | UV + `pyproject.toml` | 8888 |
| JupyterLab (Micromamba) | `~/micromamba` | Micromamba + `env.yml` | 8889 |

Both include `start.sh`, a hello-world notebook, and `.vscode/settings.json` for automatic kernel selection.

## Prerequisites

- **AWS CLI** configured with valid credentials
- **Ansible** installed locally (`pip install ansible`)

## Deploy

### 1. Create the key pair (first time only)

```bash
aws ec2 create-key-pair \
  --key-name ec2-key \
  --region eu-west-1 \
  --query 'KeyMaterial' \
  --output text > ec2-key.pem
chmod 600 ec2-key.pem
```

### 2. Launch the instance

```bash
aws cloudformation create-stack \
  --stack-name ec2-console \
  --template-body file://cloudformation.yaml \
  --parameters ParameterKey=KeyName,ParameterValue=ec2-key \
  --region eu-west-1

# Wait and get the IP
aws cloudformation wait stack-create-complete \
  --stack-name ec2-console --region eu-west-1

aws cloudformation describe-stacks \
  --stack-name ec2-console --region eu-west-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
  --output text
```

### 3. Provision with Ansible

Run everything:

```bash
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml
```

Or run only specific components using tags:

```bash
# Only install Docker and the desktop environment
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml --tags "docker,desktop"

# Only terminal tooling and code-server
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml --tags "terminal,code-server"

# Only deploy the boilerplate projects
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml --tags projects
```

Available tags:

| Tag | What it provisions |
|---|---|
| `base` | System update + common packages (always runs) |
| `awscli` | AWS CLI v2 |
| `docker` | Docker CE + Compose plugin + ubuntu group membership |
| `uv` | UV package manager |
| `micromamba` | Micromamba package manager |
| `desktop` | XFCE4 desktop + xrdp server (port 3389) |
| `terminal` | Kitty, Nerd Fonts, oh-my-posh, Zellij |
| `browser` | Chromium |
| `code-server` | VS Code in the browser (port 8080) |
| `projects` | All boilerplate projects |
| `jupyterlab-uv` | JupyterLab UV project only |
| `jupyterlab-micromamba` | JupyterLab Micromamba project only |

The playbook is idempotent. Re-run it any time to apply updates or fix drift.

### 4. Connect

**SSH:**

```bash
ssh -i ec2-key.pem ubuntu@<public-ip>
```

**Remote Desktop (RDP):**

Connect with any RDP client to `<public-ip>:3389`. Login: `ubuntu` / `ubuntu`.

Override the default password at provision time:

```bash
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml -e ubuntu_password=yourpassword
```

**code-server (browser):**

Open `http://<public-ip>:8080` in any browser. No authentication required.

**JupyterLab:**

```bash
# SSH in, then:
cd ~/jupyterlab && ./start.sh    # http://<public-ip>:8888
cd ~/micromamba && ./start.sh     # http://<public-ip>:8889
```

## VS Code Remote SSH

### SSH config

**Windows** (`C:\Users\<user>\.ssh\config`):

```
Host ec2-console
    HostName <public-ip>
    User ubuntu
    IdentityFile C:\Users\<user>\.ssh\ec2-key.pem
```

Lock down the key (PowerShell):

```powershell
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

When the EC2 IP changes, only update the `HostName` line.

## Tear down

```bash
aws cloudformation delete-stack \
  --stack-name ec2-console --region eu-west-1
```

## Project structure

```
.
├── cloudformation.yaml                         # EC2 + security group
├── playbook.yml                                # Main playbook (imports tasks/)
├── ansible.cfg
├── inventory.yml
├── tasks/
│   ├── base.yml                                # System packages
│   ├── awscli.yml                              # AWS CLI v2
│   ├── docker.yml                              # Docker CE + Compose
│   ├── uv.yml                                  # UV package manager
│   ├── micromamba.yml                           # Micromamba
│   ├── desktop.yml                             # XFCE4 + xrdp
│   ├── terminal.yml                            # Kitty, Nerd Fonts, oh-my-posh, Zellij
│   ├── browser.yml                             # Chromium
│   ├── code-server.yml                         # VS Code in browser
│   ├── project-jupyterlab-uv.yml               # JupyterLab + UV boilerplate
│   └── project-jupyterlab-micromamba.yml        # JupyterLab + Micromamba boilerplate
├── files/
│   ├── desktop/
│   │   └── xsession                           # XFCE session config
│   ├── terminal/
│   │   ├── kitty.conf                          # Kitty terminal config
│   │   ├── zellij-config.kdl                   # Zellij config
│   │   └── 10-nerd-font-symbols.conf           # Font fallback
│   ├── code-server/
│   │   └── config.yaml                         # code-server settings
│   ├── jupyterlab/                             # UV JupyterLab boilerplate
│   └── micromamba/                             # Micromamba JupyterLab boilerplate
└── .gitignore
```

## Instance types (eu-west-1, on-demand)

| Instance | CPU | vCPU | RAM | $/hr |
|---|---|---|---|---|
| **t3a.xlarge** | AMD (burstable) | 4 | 16 GB | $0.1504 |
| c6a.xlarge | AMD (fixed) | 4 | 8 GB | $0.1530 |
| t3.xlarge | Intel (burstable) | 4 | 16 GB | $0.1664 |
| c6i.xlarge | Intel (fixed) | 4 | 8 GB | $0.1700 |
| m6a.xlarge | AMD (general) | 4 | 16 GB | $0.1728 |

Override: `--parameters ParameterKey=InstanceType,ParameterValue=c6a.xlarge`

## Extending

Create a task file in `tasks/`, import it in `playbook.yml` with a tag. Add config files under `files/`. The playbook is the single source of truth.

## Notes

- The security group opens ports **22** (SSH), **3389** (RDP), **8080** (code-server), **8888-8889** (JupyterLab) to `0.0.0.0/0`. Restrict the CIDR in `cloudformation.yaml` for tighter access control.
- The default xrdp password is `ubuntu`. Change it at provision time with `-e ubuntu_password=...` or via `passwd` after login.
- code-server runs over HTTP (no auth). Suitable for development behind a security group, not for production.
- The instance uses a **25 GB gp3** root volume. Increase `VolumeSize` in `cloudformation.yaml` if needed.
- If the account has no default VPC: `aws ec2 create-default-vpc --region eu-west-1`.

## License

MIT
