# Final cleanup and retained-resource report (ENV-10)

Final cleanup is an **explicit, separate** operation — never invoked by `stop`
or `workspace-destroy`. It releases the **persistent Elastic IP** as well as the
workspace, so it requires `--confirm`.

```bash
dbai/console.sh final-cleanup <id> --confirm --region eu-west-1
```

## Order

1. **Workspace / storage** cleanup (VM, network, firewall, key, association).
2. **Address** cleanup (the Elastic IP), only after phase 1.

Then a **retained-resource report** lists any instances, volumes or addresses
still tagged for the environment. If anything remains, the command stays
**nonzero** until it is accounted for. Repeating final cleanup is safe when some
or all resources are already gone.

## Exam environments

Do **not** run final cleanup on a practical-exam environment until evidence is
collected and grades permit. Practical environments are retained through
grading; only then release them.

## Billing categories (what actually costs money)

- **Compute** — the running instance (`stop` pauses this; final cleanup removes it).
- **Storage** — the EBS root volume (retained while the instance exists; removed
  with the instance on final cleanup).
- **Address** — the Elastic IP is billable while allocated, especially when not
  associated with a running instance; final cleanup releases it.

Budget **notifications are emails, not caps** — they never stop or delete
resources. This runbook shows no historical cost estimates; check current AWS
pricing. Final cleanup's report is the source of truth for what remains.
