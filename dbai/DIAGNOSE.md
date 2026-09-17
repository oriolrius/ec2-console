# diagnose — environment status and prerequisite diagnostics (ENV-11)

```bash
dbai/console.sh diagnose <id>              # full local diagnostic
dbai/console.sh diagnose <id> --redacted   # professor-shareable view
dbai/console.sh doctor  --region <r>       # controller-only prerequisites (ENV-05)
```

`diagnose` is **read-only** — it never creates, changes or destroys anything. It
prints the environment identity (account, region, environment, phase/profile,
baseline/module versions, active root, instance, EIP) and a set of prerequisite
checks, then a `healthy` / `FAILED` summary (nonzero exit on failure).

## Checks and what each failure means

| Check | FAIL means |
|---|---|
| `credentials` | No/expired AWS session, or the session account ≠ the environment account. Re-run your sandbox login. |
| `tools` | A required controller tool is missing (terraform/aws/python3/ssh). |
| `terraform` | No workspace state — the environment was never initialized on this controller. |
| `profile` | The recorded profile version is not in the catalog (drift / wrong checkout). |
| `workspace` | The instance is `stopped` (start it) or unreachable/terminated (rebuild). |

Failures are distinguished by category so support can tell a credential problem
from a Terraform problem from a boot/readiness problem. (During provisioning,
`initialize` further labels boot failures `[layer: terraform|bootstrap|readiness]`.)

## Sharing with the instructor (redacted)

`--redacted` omits controller-local filesystem paths and prints only the
environment identity plus each check's result — enough to triage without
exposing anything private. The manifest itself holds **no** private keys, AWS
credentials, course keys or tokens (only public identities and key *paths*), so
even the full view carries no secrets.

```bash
dbai/console.sh diagnose <id> --redacted > share-with-professor.txt
dbai/scripts/secret-sentinel.sh share-with-professor.txt   # confirms no secrets
```

The bundled secret-sentinel confirms diagnostic output emits no private-key or
credential values before you share it.
