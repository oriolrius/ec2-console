# Workspace destroy / rebuild (ENV-09)

The destructive workspace drill runs from the **controller** (never the VM it
destroys). It removes **workspace** resources (network, firewall, key, VM,
association) while preserving the **address** (Elastic IP), address state,
controller state and controller-held keys — so a rebuild keeps the same public
IP.

```bash
dbai/console.sh workspace-destroy <id> --evidence-synced   # destroy workspace only
dbai/console.sh rebuild          <id> --evidence-synced   # destroy + rebuild (reuses the EIP)
```

## Evidence-sync precondition (required)

Both commands **refuse** without `--evidence-synced` and state the missing
condition. Before a graded destructive drill or before destroying an exam
workspace, **push your coursework/exam evidence** to your Git repos (and GHCR
for images) — the VM disk is discarded by the destroy. The flag asserts you have
done so.

## Practice vs exam evidence retention

- **S6–S7 practice**: destroying the workspace is the exercise; the address
  state is retained so you rebuild onto the same IP. Losing the VM disk is
  expected — your work lives in Git.
- **Practical exam (S7/S14)**: evidence retention is mandatory. Sync every
  required artifact first; there is no automatic disk backup and no substitute
  environment. Only then run the destructive step.

## What a rebuild guarantees

Rebuild records the **new** instance id and reuses the **retained** allocation,
so the public IP is unchanged. If the rebuild's apply or boot/readiness check
fails, it exits nonzero and never reports a healthy rebuilt workspace
(see [INITIALIZE.md](./INITIALIZE.md) readiness layers).
