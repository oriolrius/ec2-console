# DBAI access keys — what goes where, and when

Four distinct keys touch a course environment. Keep them straight: three are
**inbound public** keys authorized *on the VM*; one is an **outbound** key the
VM uses to reach GitHub. **No private key ever enters Git, cloud-init, the
manifest or logs** — only public keys and controller-local key *paths*
(RECOVERY-R009).

| Key | Direction | Lives (private part) | Enrolled / restored | Purpose |
|---|---|---|---|---|
| **Student access** (`dbai.pem`) | inbound to VM | controller (`~/.ssh`, `dbai.pem`) | from **S2**, every boot/rebuild | student SSH / VS Code Remote |
| **S5 deploy** | inbound to VM | GitHub Actions secret | enrolled in **S5**, before S6; restored every boot | CI deploys to the VM over SSH |
| **Instructor** | inbound to VM | instructor controller | required from **S6**; restored on the assigned env | fault injection for the midterm and final-exam assessment |
| **VM → GitHub** | outbound from VM | on the VM (regenerated on rebuild) | created on the VM; registered as a GitHub deploy key | the VM pulls course/app repos |

## How inbound keys are enrolled

The workspace module authorizes the **public** keys at boot via cloud-init
`ssh_authorized_keys` (rendered from `authorized_keys`), and the student login
key is also set as the instance `aws_key_pair`. Keys are installed through the
key-authenticated boot — **never** password login (RECOVERY-R007). The student
key is always enrolled; the deploy and instructor keys enroll when their
`*_public_key_path` input is supplied (they are `null` until their phase).

```bash
# Enroll the S5 deploy key in the controller BEFORE the S6 adoption: run
# initialize again with the same profile and access key, plus the deploy key.
dbai/console.sh initialize --environment-id <id> --profile containers \
  --ssh-public-key ~/.ssh/dbai.pub --deploy-public-key ~/.ssh/gha-deploy.pub
dbai/console.sh status <id>     # inputs.deploy_public_key_path names the key
# The plan is "0 to add, 1 to change, 0 to destroy": the user data of the
# instance, updated in place (AWS stops and starts the instance; disk, instance
# id and EIP stay). cloud-init reads user data at the FIRST boot only, so the
# running VM keeps the key that `ssh-copy-id` installed in S5, and every later
# rebuild installs it from the profile. Without this step the S6 student root
# either plans a change (path in terraform.tfvars) or rebuilds a VM that the
# S5 pipeline cannot reach (no path). The instructor key likewise from S6.

# phase-aware readiness (does not block earlier phases):
dbai/console.sh check-keys --phase S2 --student ~/.ssh/dbai.pub
dbai/console.sh check-keys --phase S6 --student ~/.ssh/dbai.pub \
  --deploy ~/.ssh/deploy.pub --instructor ~/.ssh/instructor.pub
```

Readiness rule: **student** key required from S2; **deploy** from S5; **instructor**
from S6. A key missing when its phase requires it fails readiness; missing a
later-phase key does not block an earlier phase.

## Repeatability

Reapplying bootstrap is idempotent: the same `authorized_keys` render to the
same cloud-init, so a VM replacement restores key-only access for every enrolled
identity. The **outbound** VM→GitHub key is regenerated on the new VM and
re-registered as a GitHub deploy key — it is not an inbound authorized key.

## Sentinel

```bash
dbai/scripts/secret-sentinel.sh                     # scan tracked files
dbai/scripts/secret-sentinel.sh /tmp/rendered-cloud-init.yaml  # + a rendered artifact
```
Fails if any private-key or credential value appears in tracked files (or a
supplied artifact). Public keys and key *paths* are allowed.
