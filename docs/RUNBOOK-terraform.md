# Runbook: launch your ec2-console with Terraform

Follow these steps in order. When you finish, you will have an Ubuntu workstation on AWS with a graphical desktop that you open in your browser through Chrome Remote Desktop.

**Time needed:** about 30 minutes. Most of it is waiting for step 6.

**Where to run the commands:**
- **Linux / macOS:** a normal terminal.
- **Windows:** an **Ubuntu (WSL2)** terminal, not PowerShell.

---

## 1. Install the tools (first time only)

You need `git`, the AWS CLI v2, Terraform (1.5 or newer) and `uv`.

| Tool | How to install |
|---|---|
| git | `sudo apt install git` (macOS: `brew install git`) |
| AWS CLI v2 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Terraform | https://developer.hashicorp.com/terraform/install |
| uv | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

Check that all four work:

```bash
git --version && aws --version && terraform version && uv --version
```

## 2. Get the code (first time only)

```bash
git clone https://github.com/oriolrius/ec2-console.git
cd ec2-console
uv sync
```

Run every remaining command from inside this `ec2-console` folder.

## 3. Log in to AWS

1. Open the AWS sandbox portal your instructor gave you, and sign in.
2. Find your account and click **Access keys**.
3. Copy the block under **Option 1: Set AWS environment variables** (three `export AWS_...` lines).
4. Paste it into your terminal, and also run:

   ```bash
   export AWS_REGION=eu-west-1
   ```

5. Check that it works. This should print your account:

   ```bash
   aws sts get-caller-identity
   ```

> These keys expire after a few hours. If a command later fails with `ExpiredToken`, repeat this step.
> If you open a new terminal, you must paste them again.

## 4. Create your SSH key (first time only)

```bash
aws ec2 create-key-pair --key-name ec2-key \
  --query 'KeyMaterial' --output text > ec2-key.pem
chmod 600 ec2-key.pem
```

Keep `ec2-key.pem` safe: it is the only way into your machine. Never share it or commit it to git.

> If you get `InvalidKeyPair.Duplicate`, the key already exists in AWS. If you still have `ec2-key.pem`, skip this step.
> If you lost the file, first run `aws ec2 delete-key-pair --key-name ec2-key`, then repeat this step.

## 5. Launch the machine

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Type `yes` when it asks. After about a minute it prints `public_ip = "x.x.x.x"`. Save that IP in a variable:

```bash
IP=$(terraform -chdir=terraform output -raw public_ip)
echo $IP
```

## 6. Install the software

```bash
JUPYTER_IP=$IP uv run ansible-playbook playbook.yml
```

This takes about 15 minutes. It installs the desktop, Chrome Remote Desktop, VS Code, Docker, the Kubernetes tools, and the rest.

It is finished when you see a `PLAY RECAP` line with `failed=0`. If it fails partway, run the same command again. It continues where it stopped.

## 7. Connect over SSH

```bash
ssh -i ec2-key.pem ubuntu@$IP
```

The first time, type `yes` to trust the machine. Leave this SSH session open, because you need it in the next step.

## 8. Set up Chrome Remote Desktop (first time only per machine)

1. On your own computer, open **https://remotedesktop.google.com/headless** in your browser and sign in with your Google account.
2. Click **Begin**, then **Next**, then **Authorize**.
3. Choose **Debian Linux**. You will see a command that starts with `DISPLAY= /opt/google/chrome-remote-desktop/start-host ...`. Click the copy button.
4. Paste that command into the **SSH session from step 7** and press Enter.
5. When asked, type a **6-digit PIN** twice. Remember it: you need it every time you connect.
6. Restart the machine. This is required the first time:

   ```bash
   sudo reboot
   ```

   The SSH session closes. That is normal.
7. Wait about 30 seconds. Then open **https://remotedesktop.google.com/access**. Your machine appears as **Online**.
8. Click it and enter your PIN. The XFCE desktop opens.

> The authorization code from step 3 expires after a few minutes. If step 4 fails, go back to step 1 of this section and generate a new command.

**If the machine shows as offline or "disabled",** connect over SSH and run:

```bash
sudo systemctl restart chrome-remote-desktop@ubuntu
```

If it is still offline, run `sudo reboot` and wait 30 seconds.

## 9. Save money: stop the machine when you are not using it

A running machine costs money every hour, and a stopped one almost nothing.

```bash
ID=$(terraform -chdir=terraform output -raw instance_id)
aws ec2 stop-instances  --instance-ids $ID    # stop
aws ec2 start-instances --instance-ids $ID    # start again later
```

After a start, the **public IP changes**. Get the new one with:

```bash
terraform -chdir=terraform apply -refresh-only -auto-approve
IP=$(terraform -chdir=terraform output -raw public_ip)
```

Chrome Remote Desktop keeps working after a stop/start. You don't need to set it up again.

## 10. Delete everything at the end

```bash
terraform -chdir=terraform destroy
```

Type `yes`. This deletes the machine and **all files on it**, so copy anything you need first.

Don't delete the `terraform/terraform.tfstate` file while the machine exists. Terraform needs it to find and delete your machine.
