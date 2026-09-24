# Restore both applications after a lost VM (RECOVERY-06)

`recover` and [REBUILD](./REBUILD.md) bring the **workspace** back; this runbook
takes over where they stop and restores the **two course applications** —
`hello-world` (the S2–S5 app) and the S4/S5 `ai-workbench` (pi-web-ui + Qdrant
talking to the LiteLLM gateway) — onto the replacement VM through the documented
credential and Git bootstrap, with **no manual, unversioned fallback**.

It is the S6 "full recovery" route: everything that only lived on the old VM's
disk is gone (doc-18 §2), so restoration is *re-derived from what survived* —
controller/address state, your pushed repositories, the images in GHCR and the
secrets in your external store — never from an ad-hoc rebuild by hand.

The route is ordered; **each step gates the next** and fails loudly rather than
degrading to an unversioned deploy. Run it from the persistent controller.

---

## 0. Confirm the survivors before anything destructive (AC#1)

A lost VM must never cost you graded work. Before you rebuild, verify that
everything restoration *depends on* actually survived — and that nothing
un-synced is about to be discarded silently.

```bash
dbai/console.sh recover <id>            # triage: prints the route, exits nonzero until healthy
dbai/console.sh doctor <id> --redacted  # professor-safe survivor check
```

Confirm each survivor is present **before** you destroy the workspace:

| Survivor | Where it lives | Check |
|---|---|---|
| Controller Terraform state | controller (isolated backend, ENV-02) | `console.sh doctor` reports controller state present |
| Address state + EIP | its own state (ENV-03) | `init-address` reports the EIP **reused**, not allocated |
| Private access/deploy keys | controller, not the VM | key files present on the controller; never on VM disk |
| External course/GHCR credentials | your secret store (not Git, not VM) | you can read `COURSE_VIRTUAL_KEY` + a GHCR PAT out-of-band |
| Pushed exam branch / journal / images | GitHub + GHCR | `git ls-remote` shows your branch; `docker manifest inspect` shows the image |

`rebuild` **refuses without `--evidence-synced`** precisely so this step cannot
be skipped. If any survivor above is missing, stop: that gap cannot be recovered
by rebuilding, and it must be recorded honestly in the evidence (doc-18 §2).

Then rebuild and re-establish trust in the host **before** you push any secret
to it:

```bash
dbai/console.sh rebuild <id> --evidence-synced   # ENV-09: retains EIP + address state
dbai/console.sh verify-host <id>                 # RECOVERY-05: trust the NEW host key (RECONNECT.md)
```

A replaced VM has a new host key; `verify-host` is mandatory before the first
SSH — never disable host checking to "get back in faster".

---

## 1. Renew the VM's outbound GitHub identity and clone both repos (AC#2)

The old VM's **outbound** deploy key (the key the VM used to pull from GitHub) died
with it. Generate a fresh one on the replacement VM, register it as a
**read-only deploy key** on each repository, then clone. This identity is
distinct from the **inbound** key the controller/SSH-Action uses to reach the VM
(§4) — the runbook and logs keep the two apart (AC#6).

```bash
# on the replacement VM, over the verified tunnel:
ssh dbai@<id> 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/gh_deploy -C "vm-<id>-outbound"'
ssh dbai@<id> 'cat ~/.ssh/gh_deploy.pub'      # register as a READ-ONLY deploy key on each repo
```

Register that **public** key as a deploy key (read-only) on `oriolrius/hello-world`
and `oriolrius/ai-workbench`, then clone both and re-add each upstream remote so
future syncs still work:

```bash
ssh dbai@<id> '
  git clone git@github.com:oriolrius/hello-world.git ~/hello-world
  git -C ~/hello-world remote add upstream https://github.com/oriolrius/hello-world.git

  git clone git@github.com:oriolrius/ai-workbench.git ~/ai-workbench
  git -C ~/ai-workbench remote add upstream https://github.com/oriolrius/ai-workbench.git
'
```

Restore **GHCR pull authentication** so the VM can pull the release images. The
course images (`ghcr.io/oriolrius/hello-world`, `.../pi-web-ui`,
`.../qdrant`) are public, but log in anyway with a `read:packages` PAT so the
route also works for a private image and so pulls are attributable:

```bash
ssh dbai@<id> 'echo "$GHCR_PAT" | docker login ghcr.io -u <ghcr-user> --password-stdin'
```

Only the **public** deploy key and the PAT's effect (a successful `docker login`)
are ever emitted — never a private key or the PAT value (AC#6).

---

## 2. Verify the committed registry Compose before redeploying (AC#3)

hello-world deploys **only** from its committed, registry-pinned
`~/hello-world/compose.yml` — an explicit immutable GHCR tag, never a local build
and never `:latest` (APP-10). Verify it resolves before you redeploy; a missing
file or a failed registry login **fails restoration** here rather than sliding
into a hand-rolled `docker run`.

```bash
ssh dbai@<id> '
  test -f ~/hello-world/compose.yml || { echo "FAIL: no committed compose.yml — do NOT hand-deploy"; exit 1; }
  cd ~/hello-world
  GHCR_NAMESPACE=oriolrius HELLO_IMAGE_TAG=<current-release-tag> \
    docker compose config >/dev/null || { echo "FAIL: registry compose did not resolve"; exit 1; }
'
```

The committed fixture is the contract enforced by `tests/test_compose_registry.py`
in the hello-world repo: a missing/empty `HELLO_IMAGE_TAG` is **rejected**, and a
release tag resolves to exactly `ghcr.io/oriolrius/hello-world:<tag>` with no
`build:` and no `:latest`. If this step fails, fix the credential/clone problem
above — do **not** fall back to an unversioned deployment.

---

## 3. Release the next hello-world version through the S5 pipeline (AC#4)

Restoration finishes hello-world by **shipping the next version through the
existing pipeline**, not by copying an image onto the VM by hand. The replacement
VM reuses the retained EIP, so `VM_HOST` and `VM_SSH_KEY` are **unchanged** — the
same release workflow deploys to it exactly as before (APP-09/APP-11).

```bash
# in the hello-world repo (controller / CI), not on the VM:
cz bump                       # MINOR/PATCH -> new vX.Y.Z tag (APP-08)
git push --follow-tags        # triggers release.yml: test -> build+push GHCR -> deploy over SSH
```

`release.yml` runs quality → builds and pushes `ghcr.io/oriolrius/hello-world:vX.Y.Z`
→ SSH-deploys to `VM_HOST` with `VM_SSH_KEY` (both unchanged), pinning
`HELLO_IMAGE_TAG=vX.Y.Z` into the committed compose. Prove the **new** version
serves on the replacement VM:

```bash
curl -s http://localhost:8000/ | jq -r '.message, .hostname'    # over the tunnel
# hostname = the NEW instance; message reflects the new release
git -C ~/hello-world rev-parse HEAD    # matches the just-released tag's commit
```

A curl that returns the new greeting from the new hostname is the AC#4 evidence.
The mechanics here are exactly those qualified in APP-11 (release pipeline
deployed the pinned tag to a live VM and curl confirmed it) — the recovery route
only adds "on a **replacement** VM with unchanged `VM_HOST`/`VM_SSH_KEY`".

---

## 4. Restore the workbench stack and prove a gateway chat (AC#5)

The workbench's `.env` is **git-ignored** (it holds `COURSE_VIRTUAL_KEY`) so it
did not survive in the repo — recreate it from your external secret store, never
from Git or a screenshot. Then bring up the pinned Compose stack and prove a
real course-key chat round trip through the restored S4 SSH tunnel.

```bash
ssh dbai@<id> '
  cd ~/ai-workbench
  cp .env.example .env
  # write COURSE_VIRTUAL_KEY from the secret store into .env (out-of-band; never echoed to logs)
  docker compose up -d      # pi-web-ui:1.0.0 + qdrant:v1.15.0, 127.0.0.1 binds, healthchecks
  docker compose ps         # both services healthy
'
```

Open the S4 loopback tunnel and prove the gateway answers with the student key —
the same round trip qualified in WB-05, now on the nan.builders course chat alias
`course-chat` (the legacy name `claude-haiku-free` is key-aliased to it):

```bash
ssh -N -L 8080:127.0.0.1:8080 dbai@<id> &     # S4 tunnel to pi-web-ui
curl -s http://localhost:8080/health          # workbench UI reachable over the tunnel
# gateway round trip with the restored key (never printed):
curl -s https://litellm.joor.net/v1/chat/completions \
  -H "Authorization: Bearer $COURSE_VIRTUAL_KEY" \
  -d '{"model":"course-chat","messages":[{"role":"user","content":"WB recovery ping"}]}' \
  | jq -r '.choices[0].message.content'        # a real completion == AC#5 evidence
```

A non-empty completion returned through the tunnel, authenticated by the
restored `COURSE_VIRTUAL_KEY`, closes AC#5. The workbench compose and the
gateway alias are the ones qualified in WB-04/WB-05 and GATEWAY-01.

---

## 5. What the logs and evidence must distinguish (AC#6)

The recovery record must keep the three credential identities separate and must
contain **no secret value**:

| Identity | Direction | What changed on recovery | What may be logged |
|---|---|---|---|
| VM outbound GitHub deploy key (`~/.ssh/gh_deploy`) | VM → GitHub | **renewed** (new keypair, §1) | the **public** key + which repos it was registered on |
| Controller/SSH-Action inbound key (`VM_SSH_KEY` → `VM_HOST`) | controller/CI → VM | **unchanged** (retained EIP, §3) | that it was reused; never the key |
| VM host key (SSH server identity) | VM presents to clients | **new** (new instance) — re-trusted via `verify-host` | the new fingerprint (RECONNECT.md) |
| GHCR PAT / `COURSE_VIRTUAL_KEY` | VM/UI → GHCR / gateway | re-supplied from the secret store | only the **effect** (login OK, chat OK) |

Optionally, if you rotate the SSH-Action's known-hosts, record the **updated
fingerprint** — not the key. Nothing in this list writes a private key, PAT or
virtual key into Git, the journal or the evidence record; secrets move only
out-of-band from your external store.

---

## Order, gates and honesty

1. **Survivors verified** (§0) → else stop; the gap is unrecoverable and recorded.
2. **Rebuild + host trust** (§0) → else no safe channel to the VM.
3. **Outbound identity + clones + GHCR auth** (§1) → else nothing to deploy from.
4. **Committed registry compose verified** (§2) → else fail, never hand-deploy.
5. **Release through the pipeline; curl proves the new version** (§3).
6. **Workbench .env from the secret store; gateway chat proves the tunnel** (§4).
7. **Evidence distinguishes the identities; no secret leaks** (§5).

Each step exits nonzero on failure, so a half-restored environment is never
reported as recovered. When every step passes, capture
`console.sh diagnose <id> --redacted` as the RECOVERY-06 evidence and hand off to
the S6 measurement (RECOVERY-07) and the assessment preflight (M11).

See also: [RECOVERY](./RECOVERY.md) (triage/routes), [REBUILD](./REBUILD.md)
(workspace rebuild), [RECONNECT](./RECONNECT.md) (host-key trust),
[BACKUP](./BACKUP.md) (controller state restore).
