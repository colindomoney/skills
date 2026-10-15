---
name: forgejo-etckeeper
description: Version /etc with etckeeper on a Debian/Ubuntu host and auto-push every commit (apt runs, daily autocommit, manual etckeeper commit) to a private per-host repo on Forgejo, using a write-enabled SSH deploy key or a repo-scoped token. Use when setting up etckeeper, asked to "put /etc in git", "back up /etc to Forgejo", "set up etckeeper pushing to git.domoney.online", bringing a new host into the Infrastructure org, or when etckeeper commits are not reaching the remote.
license: MIT
metadata:
  author: colindomoney
  tags: "forgejo, etckeeper, git, debian, ssh, systemd"
  version: "0.1.1"
  last-verified: "2026-10-15"
  status: live
---

# Forgejo: etckeeper with auto-push

Every host keeps /etc in git via etckeeper, and every etckeeper commit is pushed to its own private repo `Infrastructure/<hostname -s>-etc` on Forgejo (`git.domoney.online`). Pushing is done by etckeeper's own `PUSH_REMOTE` hook rather than a cron job, so apt-triggered, timer-triggered and manual commits all go out the same way. Credentials are a per-host deploy key scoped to that one repo, never a user's key or a broad token, because /etc contains `shadow` and the SSH host private keys.

## When to use / when not to

- Use when: a Debian/Ubuntu (apt/dpkg) host needs /etc versioned and pushed off-box.
- Don't use when: the host is not apt/dpkg (stop; etckeeper config differs), or the host is declaratively managed (NixOS, image-built) and /etc is not the source of truth.

## Parameters

Ask for any you can't determine; don't guess.

| Name | Default |
|---|---|
| `FORGEJO_HOST` | `git.domoney.online` |
| `FORGEJO_SSH_PORT` | `22` (host OpenSSH with Forgejo passthrough; confirm) |
| `FORGEJO_OWNER` | `Infrastructure` (org) |
| `REPO` | `$(hostname -s)-etc` |
| `GIT_IDENTITY` | `etckeeper <etckeeper@$(hostname -f)>` |
| `AUTH_MODE` | `deploy-key` (or `token`) |

## The canonical form

From host `devgw` (Debian 13), running.

`/etc/etckeeper/etckeeper.conf`, the only change from the Debian default:

```diff
-PUSH_REMOTE=""
+PUSH_REMOTE="origin"
```

(`VCS="git"`, `HIGHLEVEL_PACKAGE_MANAGER=apt`, `LOWLEVEL_PACKAGE_MANAGER=dpkg` are already the default.)

`/root/.ssh/config` (mode 600):

```
Host forgejo-etc
    HostName git.domoney.online
    Port 22
    User git
    IdentityFile /root/.ssh/etckeeper_ed25519
    IdentitiesOnly yes
```

Remote: `git@forgejo-etc:Infrastructure/<host>-etc.git`.

## Steps

Check state before each step and skip what is already done. Never discard existing /etc history without asking. Show the user a diff of any file changed outside /etc/.git before writing it.

1. **Distro.** `cat /etc/os-release`; stop unless Debian/Ubuntu. Check `/etc/.git`, `git -C /etc branch`, `git -C /etc remote -v`, `/root/.ssh/`.
2. **Branch default.** `sudo git config --global init.defaultBranch main`. Nothing else in root's global config. Do this *before* installing: the package creates /etc/.git and commits on install.
3. **Install.** `sudo apt-get install -y etckeeper`. If /etc/.git was pre-existing on `master`: `git -C /etc branch -m master main`.
4. **Config.** Set `PUSH_REMOTE="origin"`.
5. **One autocommit path.** Keep `etckeeper.timer`, disable the cron script persistently:
   ```sh
   systemctl is-active etckeeper.timer cron anacron
   sudo dpkg-statoverride --update --add root root 0644 /etc/cron.daily/etckeeper
   run-parts --test /etc/cron.daily | grep etckeeper || echo skipped
   ```
6. **Identity, repo-local only.** `git -C /etc config user.name etckeeper`; `git -C /etc config user.email etckeeper@$(hostname -f)`.
7. **Credentials (deploy-key).**
   - `ssh-keygen -q -t ed25519 -N '' -C "etckeeper@$(hostname -s)" -f /root/.ssh/etckeeper_ed25519` (skip if present), mode 600.
   - Write the `Host forgejo-etc` block above.
   - `ssh-keyscan -p <port> <host> > keyscan; ssh-keygen -lf keyscan`. **Stop**: user confirms fingerprints against the Forgejo host before you append to `/root/.ssh/known_hosts`.
   - Print `/root/.ssh/etckeeper_ed25519.pub`. **Stop** while the user creates `<owner>/<repo>` (private, empty, no README/licence/.gitignore) and adds the key as a deploy key **with write access**. Wait for "done".
   - Token mode instead: token limited to "Specific repositories" → this repo, `write:repository`; store in `/root/.git-credentials-etckeeper` (600); `git -C /etc config credential.helper "store --file=/root/.git-credentials-etckeeper"`; remote `https://<host>/<owner>/<repo>.git`.
8. **Confirm private and empty.**
   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' https://<host>/api/v1/repos/<owner>/<repo>   # expect 404 anonymously
   sudo git ls-remote git@forgejo-etc:<owner>/<repo>.git | wc -l                      # expect 0
   ```
   200 anonymously means public: stop. Refs present means not empty: stop, never `--allow-unrelated-histories`.
9. **Remote.** `git -C /etc remote add origin <url>` (or `set-url`); remove stale remotes (e.g. an old `gitlab`).
10. **First push.** `etckeeper commit "Initial commit on $(hostname -s)"` if `git status --porcelain` is non-empty, then `git -C /etc push -u origin main`.

## Gotchas

- **etckeeper sometimes initialises /etc/.git on `master`, not `main`.** It runs `git init` as root, so it only gets `main` if root's `init.defaultBranch` was set *before* the install (or before any earlier `etckeeper init`). Always check `git -C /etc branch` after step 3 and rename with `git -C /etc branch -m master main` before adding the remote. If a remote already has `master`, stop and ask; don't push both.
- **Both daily autocommits run on Debian 13.** `/etc/cron.daily/etckeeper` has no systemd guard and, without anacron, `/etc/crontab` runs it via `run-parts` alongside `etckeeper.timer`. Use `dpkg-statoverride`, not `chmod -x`, or a package upgrade restores the mode.
- **The first `etckeeper commit` after adding the remote prints `fatal: The current branch main has no upstream branch`.** The `PUSH_REMOTE` hook runs `git push origin` before `-u` has been set. Harmless; the following `push -u origin main` fixes it for good.
- **The author is the sudo user, not the repo identity.** etckeeper sets the author from `SUDO_USER`'s git config; `user.name`/`user.email` in /etc/.git/config only apply as committer, or as author for timer and unattended-upgrade commits.
- **`hostname -f` may return the bare short name** (no domain configured), giving `etckeeper@<host>`. Ask whether a domain is wanted.
- **Port probing:** only 22 answers on `git.domoney.online` (OpenSSH 9.6p1 Ubuntu banner). That does not tell you whether it's Forgejo passthrough; confirm with the user.
- **Deploy key visibility:** a deploy key can read a private repo over SSH, so SSH success says nothing about visibility. Check anonymously over HTTPS.
- **Never** copy a user's SSH key into /root, use a plain `credential.helper store`, or add a cron job to push.

## Verify

```sh
sudo touch /etc/etckeeper-test && sudo etckeeper commit "push test"
sudo git -C /etc rev-parse HEAD; sudo git -C /etc ls-remote origin refs/heads/main   # same hash, no manual push
sudo git -C /etc rm -q /etc/etckeeper-test && sudo etckeeper commit "Remove push test file"
sudo git -C /etc status            # clean, up to date with origin/main
sudo etckeeper vcs log --oneline -3
```

Report: files changed, deploy key fingerprint (`ssh-keygen -lf /root/.ssh/etckeeper_ed25519.pub`) or token name/expiry, which autocommit mechanism is active, anything skipped.

## References

- Running instance: host `devgw`, repo `Infrastructure/devgw-etc` on `git.domoney.online`.
