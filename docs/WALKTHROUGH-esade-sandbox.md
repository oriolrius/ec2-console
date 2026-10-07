# Walkthrough: a recorded launch of ec2-console in the ESADE AWS sandbox

This is a **real, recorded run** of [RUNBOOK-terraform.md](RUNBOOK-terraform.md) on 2026-10-07. Every command below was actually executed. The output shown is the real output, trimmed only where noted; the complete logs are in [`assets/walkthrough-esade-sandbox/logs/`](assets/walkthrough-esade-sandbox/logs/). The web steps are real screenshots, annotated in red to show what to click and why.

Use it next to the runbook: the runbook tells you **what** to do, and this walkthrough shows **what you should see**.

> Secrets are never shown. Passwords, MFA codes and AWS keys are masked (magenta boxes) in the screenshots, and the private SSH key never appears in a log.

## Recording context

| Item | Value |
| ---- | ----- |
| Date | 2026-10-07 (UTC times in the logs) |
| ec2-console version | `main` at `18057c9` (after release v1.9.0), fresh `git clone` |
| Controller | Windows 11 + WSL2 Ubuntu (the student laptop) |
| Sandbox account | `aws.esade.lab114` (753916465480), lease template `CloudSolutionsLease` |
| AWS role | `esadeis_IsbUsersPS`, the **student** role |
| Region | `eu-west-1` (Ireland) |

---

## Part 1: get AWS credentials from the ESADE sandbox (web)

### 1.0 (Only if you have no active lease) Request a lease

Open the **Innovation Sandbox on AWS** web app with the link your instructor gives you and click **Request a new lease**. Pick the template your instructor names, accept the terms and submit. An instructor must approve it, so request it ahead of time.

![Request a lease: choose the template, accept the terms, submit; an instructor approves](assets/walkthrough-esade-sandbox/00-request-lease.png)

In this recording a lease was already active, so nothing was submitted.

### 1.1 Sign in

The sandbox uses its own AWS sign-in (IAM Identity Center), not your ESADE Microsoft account. It asks for three things in a row: username, password, and a 6-digit MFA code.

![Sign in, step 1: username](assets/walkthrough-esade-sandbox/02-signin-username-filled.png)

![Sign in, step 2: password (masked)](assets/walkthrough-esade-sandbox/03-signin-password.png)

![Sign in, step 3: MFA code from your authenticator app](assets/walkthrough-esade-sandbox/04-signin-mfa.png)

### 1.2 Open your leased account

After signing in you land on the Innovation Sandbox home page. **My Leases** shows your account, when the lease expires, and how much of the budget is used. Click **Login to account**: it opens the AWS access portal in a new tab.

![Innovation Sandbox home: your active lease and the Login to account button](assets/walkthrough-esade-sandbox/05-after-login.png)

### 1.3 Get the access keys for the student role

The access portal lists the roles you can use in that account. Click **Access keys** next to **`esadeis_IsbUsersPS`**.

![Access portal: click Access keys for the student role](assets/walkthrough-esade-sandbox/06-account-roles.png)

A dialog shows your temporary credentials. In the **macOS and Linux** tab, copy the **Option 1** block: three `export AWS_...` lines. You paste them into your terminal in step 3 below.

![Credentials dialog: copy Option 1 (keys masked in this screenshot)](assets/walkthrough-esade-sandbox/07-access-keys-dialog.png)

---

## Part 2: launch the machine (terminal)

All commands run in an Ubuntu (WSL2) terminal. Each block shows the command, then its output.

### Step 1. Check the tools

```console
$ git --version && aws --version && terraform version && uv --version
git version 2.34.1
aws-cli/1.42.46 Python/3.10.12 Linux/6.18.33.2-microsoft-standard-WSL2 botocore/1.42.32
Terraform v1.16.1
on linux_amd64

Your version of Terraform is out of date! The latest version
is 1.16.5. You can update by downloading from https://developer.hashicorp.com/terraform/install
uv 0.10.9
```

All four tools answer. The "out of date" message is only a notice; any Terraform 1.5 or newer works.

> **Observation:** this laptop had **AWS CLI v1** (`aws-cli/1.42.46`) instead of the v2 the runbook asks for. Every step below still worked with v1. Installing v2 is still recommended.

### Step 2. Get the code

```console
$ git clone https://github.com/oriolrius/ec2-console.git && cd ec2-console && git log --oneline -1 && uv sync
Cloning into 'ec2-console'...
18057c9 Merge pull request #22 from oriolrius/dependabot/github_actions/astral-sh/setup-uv-10.2.0
Using CPython 3.14.3
Creating virtual environment at: .venv
Resolved 17 packages in 1ms
Installed 10 packages in 1.04s
 + ansible==13.5.0
 + ansible-core==2.20.4
 + cffi==2.0.0
 + cryptography==46.0.6
 + jinja2==3.1.6
 + markupsafe==3.0.3
 + packaging==26.0
 + pycparser==3.0
 + pyyaml==6.0.3
 + resolvelib==1.2.1
```

`uv sync` installs Ansible into the project's own `.venv`. Nothing is installed system-wide.

### Step 3. Log in to AWS

Paste the three `export` lines from section 1.3 (not shown here), then set the region and check who you are:

```console
$ export AWS_REGION=eu-west-1
$ aws sts get-caller-identity
{
    "UserId": "AROA27CHMKFEJVOFZYAUS:your.sandbox.username",
    "Account": "753916465480",
    "Arn": "arn:aws:sts::753916465480:assumed-role/AWSReservedSSO_esadeis_IsbUsersPS_9f1ca513af081798/your.sandbox.username"
}
```

Check two things: `Account` is your sandbox account, and the `Arn` contains `IsbUsersPS`, the student role.

### Step 4. Create the SSH key

```console
$ aws ec2 create-key-pair --key-name ec2-key --query 'KeyMaterial' --output text > ec2-key.pem && chmod 600 ec2-key.pem

An error occurred (InvalidKeyPair.Duplicate) when calling the CreateKeyPair operation: The keypair already exists
```

This sandbox account had been used before, so a key pair called `ec2-key` already existed in AWS, but this new clone has no matching `ec2-key.pem`. This is the runbook's *"If you lost the file"* case.

> **Observation:** the failed command still left an **empty** `ec2-key.pem` behind, because the shell creates the file for `>` before AWS answers:
>
> ```console
> $ ls -l ec2-key.pem
> -rw-rw-r-- 1 student student 0 Oct  7 11:39 ec2-key.pem
> ```
>
> An empty `.pem` can't log in to anything. Don't keep it.

Before deleting the old key pair, check that no machine uses it (empty output means none):

```console
$ aws ec2 describe-instances --filters Name=key-name,Values=ec2-key Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
```

Then delete it and create it again. This overwrites the empty file:

```console
$ aws ec2 delete-key-pair --key-name ec2-key && aws ec2 create-key-pair --key-name ec2-key --query 'KeyMaterial' --output text > ec2-key.pem && chmod 600 ec2-key.pem && ls -l ec2-key.pem && head -1 ec2-key.pem
{
    "Return": true,
    "KeyPairId": "key-060621a0ad7ba946e"
}
-rw------- 1 student student 1679 Oct  7 11:39 ec2-key.pem
-----BEGIN RSA PRIVATE KEY-----
```

The file now has 1679 bytes, permissions `-rw-------` (only you can read it), and starts with `BEGIN RSA PRIVATE KEY`.

### Step 5. Launch the machine

```console
$ terraform -chdir=terraform init
Initializing the backend...

Initializing provider plugins...
- Reusing previous version of hashicorp/aws from the dependency lock file
- Installing hashicorp/aws v5.100.0...
- Installed hashicorp/aws v5.100.0 (signed by HashiCorp)

Terraform has been successfully initialized!
```

```console
$ terraform -chdir=terraform apply
```

Terraform first prints the plan: 7 resources, all to be **created** (full plan in [`05b-terraform-apply.log`](assets/walkthrough-esade-sandbox/logs/05b-terraform-apply.log)):

```text
  # aws_instance.this will be created
  # aws_internet_gateway.this will be created
  # aws_route_table.public will be created
  # aws_route_table_association.public will be created
  # aws_security_group.this will be created
  # aws_subnet.public will be created
  # aws_vpc.this will be created

Plan: 7 to add, 0 to change, 0 to destroy.

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

Type `yes`. About 50 seconds later:

```text
aws_vpc.this: Creation complete after 12s [id=vpc-0b92294ce87dab082]
aws_internet_gateway.this: Creation complete after 0s [id=igw-0b3bf8be9810b1ce8]
aws_route_table.public: Creation complete after 2s [id=rtb-0fd38c94665cb6e96]
aws_security_group.this: Creation complete after 2s [id=sg-09a5a675e5a2d9a2a]
aws_subnet.public: Creation complete after 11s [id=subnet-0334eb8c59012f355]
aws_route_table_association.public: Creation complete after 0s [id=rtbassoc-07480616d4886d380]
aws_instance.this: Creation complete after 13s [id=i-0a4142aa5a480e68b]

Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:

ansible_command = "uv run ansible-playbook playbook.yml"
instance_id = "i-0a4142aa5a480e68b"
public_ip = "3.253.68.181"
ssh_command = "ssh -i ec2-key.pem ubuntu@3.253.68.181"
```

The student role is enough to create everything: VPC, subnet, internet gateway, security group and the instance.

```console
$ IP=$(terraform -chdir=terraform output -raw public_ip); echo $IP
3.253.68.181
```

### Step 6. Install the software

<!-- STEP6 -->

### Step 7. Connect over SSH

<!-- STEP7 -->

---

## Part 3: Chrome Remote Desktop

<!-- CRD -->

---

## Timing

<!-- TIMING -->
