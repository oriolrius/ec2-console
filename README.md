# EC2 Console

A ready-to-use cloud development workstation on AWS. Spin up an Ubuntu 24.04 EC2 instance pre-configured with modern development tooling and connect from VS Code, a terminal, or a browser.

**Infrastructure** is defined in CloudFormation (one command to create, one to destroy). **Provisioning** is handled by an idempotent Ansible playbook that can be re-run at any time to update or repair the environment.

## Included tooling

| Tool | Purpose |
|---|---|
| **AWS CLI v2** | Interact with AWS services directly from the instance |
| **Docker CE + Compose v2** | Container runtime — build and run any containerized workload |
| **UV** | Fast Python package manager — create and manage Python projects |
| **Micromamba** | Conda-compatible package manager — manage environments with conda-forge packages |

## Boilerplate projects

The playbook deploys two example projects under `/home/ubuntu/` that serve as starting points. Each one demonstrates a different approach to managing a Python-based environment:

| Project | Path | Package manager | Port |
|---|---|---|---|
| JupyterLab (UV) | `~/jupyterlab` | UV + `pyproject.toml` | 8888 |
| JupyterLab (Micromamba) | `~/micromamba` | Micromamba + `env.yml` | 8889 |

Both include a `start.sh` launcher (no-auth, bound to `0.0.0.0`), a hello-world notebook, and `.vscode/settings.json` for automatic kernel selection. They are examples — use them as-is, extend them, or replace them entirely.

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
# Only install Docker
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml --tags docker

# Only deploy the boilerplate projects
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml --tags projects

# Combine tags
JUPYTER_IP=<public-ip> ansible-playbook playbook.yml --tags "docker,uv,jupyterlab-uv"
```

Available tags:

| Tag | What it provisions |
|---|---|
| `base` | System update + common packages (always runs) |
| `awscli` | AWS CLI v2 |
| `docker` | Docker CE + Compose plugin + ubuntu group membership |
| `uv` | UV package manager |
| `micromamba` | Micromamba package manager |
| `projects` | All boilerplate projects |
| `jupyterlab-uv` | JupyterLab UV project only |
| `jupyterlab-micromamba` | JupyterLab Micromamba project only |

The playbook is idempotent. Re-run it any time to apply updates or fix drift.

### 4. Connect

```bash
ssh -i ec2-key.pem ubuntu@<public-ip>
```

## VS Code Remote SSH

The primary workflow is connecting via VS Code Remote SSH and opening project folders directly.

### SSH config

**Windows** (`C:\Users\<user>\.ssh\config`):

```
Host ec2-console
    HostName <public-ip>
    User ubuntu
    IdentityFile C:\Users\<user>\.ssh\ec2-key.pem
```

Lock down the key permissions (PowerShell):

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
3. Open a `.ipynb` file — the Python kernel auto-selects from `.vscode/settings.json`

When the EC2 IP changes after a new deployment, update the `HostName` line in your SSH config. Everything else stays the same.

## Tear down

```bash
aws cloudformation delete-stack \
  --stack-name ec2-console --region eu-west-1
```

This destroys the instance, security group, and EBS volume. The key pair persists in AWS until you delete it separately.

## Project structure

```
.
├── cloudformation.yaml            # Infrastructure (EC2 + security group)
├── playbook.yml                   # Main Ansible playbook (imports tasks/)
├── ansible.cfg                    # Ansible settings
├── inventory.yml                  # Inventory (reads JUPYTER_IP env var)
├── tasks/                         # Modular, tagged task files
│   ├── base.yml                   #   System update + common packages
│   ├── awscli.yml                 #   AWS CLI v2
│   ├── docker.yml                 #   Docker CE + Compose
│   ├── uv.yml                     #   UV package manager
│   ├── micromamba.yml              #   Micromamba package manager
│   ├── project-jupyterlab-uv.yml  #   Boilerplate: JupyterLab + UV
│   └── project-jupyterlab-micromamba.yml
├── files/                         # Boilerplate project files
│   ├── jupyterlab/
│   │   ├── pyproject.toml
│   │   ├── .python-version
│   │   ├── start.sh
│   │   ├── README.md
│   │   ├── .vscode/settings.json
│   │   └── notebooks/
│   │       └── hello_world.ipynb
│   └── micromamba/
│       ├── env.yml
│       ├── start.sh
│       ├── README.md
│       ├── .vscode/settings.json
│       └── notebooks/
│           └── hello_world.ipynb
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

Override at deploy time:

```bash
--parameters ParameterKey=InstanceType,ParameterValue=c6a.xlarge
```

## Extending

To add a new tool: create a task file in `tasks/`, import it in `playbook.yml` with a tag. To add a new boilerplate project: add files under `files/` and a corresponding task file. The playbook is the single source of truth for what gets installed.

## Notes

- The security group opens ports **22** (SSH), **8888**, and **8889** to `0.0.0.0/0`. Restrict the CIDR in `cloudformation.yaml` if you need tighter access control.
- The boilerplate projects launch JupyterLab with **no authentication token** and bound to **all interfaces** — suitable for development behind a security group, not for production.
- The instance uses a **25 GB gp3** root volume. Increase `VolumeSize` in `cloudformation.yaml` if you need more disk.
- If the account has no default VPC, create one first: `aws ec2 create-default-vpc --region eu-west-1`.

## License

MIT
