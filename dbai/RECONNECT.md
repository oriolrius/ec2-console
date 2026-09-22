# Reconnecting after a VM replacement — verify the host key (RECOVERY-05)

The persistent Elastic IP is stable, but a **rebuilt** workspace VM has a **new
SSH host key**. On the next connect your client will refuse with
`REMOTE HOST IDENTIFICATION HAS CHANGED`. The safe response is to **verify the
new key against a trusted channel** and refresh `known_hosts` — never to disable
host checking.

## The trusted channel

The instance prints its own host-key fingerprints to its boot log, which you
read through AWS (not over the untrusted network):

```bash
dbai/console.sh host-fingerprint <id>     # SHA256 fingerprints, tied to the instance id
```

This is `aws ec2 get-console-output` under the hood — the same key material the
VM generated at boot, delivered over your authenticated AWS session.

## Verified reconnect flow

```bash
# 1. Verify the live host key against the trusted console-channel key.
dbai/console.sh verify-host <id>
#    PASS  -> the live key matches the trusted fingerprint
#    REJECT (nonzero) -> mismatch or trusted fingerprint unavailable: do NOT connect

# 2. Only after PASS, refresh known_hosts (remove the stale IP entry, add the
#    verified key) and reconnect strictly:
dbai/console.sh verify-host <id> --refresh
ssh -o StrictHostKeyChecking=yes ubuntu@<ip>
```

`verify-host` fails closed: a mismatch, an unreachable host, or a console log
that has not yet published the keys all return nonzero and change nothing. It
never prints private key material and never relaxes key-only access.

## Why `accept-new` is not enough

`StrictHostKeyChecking=accept-new` auto-trusts a **previously unknown** host, but
it still **rejects a host whose key has CHANGED**. A replacement VM on the same
IP is exactly the "changed key" case, so `accept-new` does not silently accept
it — and you must not "fix" the warning by deleting `known_hosts` or setting
`StrictHostKeyChecking=no`. Remove the specific stale entry
(`ssh-keygen -R <ip>`) only **after** the fingerprint is verified.

## The GitHub Actions SSH deploy is a SEPARATE verification input

The S5 release pipeline connects to the VM from a GitHub Actions runner. Its host
verification is **its own** input — a pinned `known_hosts`/fingerprint in the
workflow or a repo secret — and is independent of your local OpenSSH client
policy. After a VM replacement you must **update that pinned Action fingerprint
too** (from the same `host-fingerprint` trusted channel), or the deploy job will
fail host verification. Updating your laptop's `known_hosts` does not update the
runner's, and vice-versa. Neither the `VM_HOST` nor `VM_SSH_KEY` deploy values
change — only the pinned host fingerprint.

## What to record

For evidence, record the **trusted** fingerprint (from `host-fingerprint`), the
**observed** fingerprint (from `verify-host`), and the pass/fail outcome. Never
commit or paste private keys.
