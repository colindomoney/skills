---
name: hermes-macos-nas-backup
description: Set up a simple daily backup of a local Hermes Agent (Nous Research) on a Mac, using `hermes backup` plus rclone over SFTP to a NAS, scheduled as a no-agent Hermes cron job. Keeps 3 zips locally and 14 days on the NAS, in a folder per machine. Use when asked to "back up my local Hermes", "back up Hermes to the NAS", "add a Hermes backup cron", or when setting up hermes-dev-backup.sh, or when rclone reports an unknown known_hosts key on this job.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, macos, backup, rclone, sftp, cron, nas"
  version: "0.1.0"
  last-verified: "2026-11-05"
  status: live
---

# Local Hermes Agent backup to a NAS

A small daily backup for a Hermes instance that is close to disposable: one script, one rclone remote, one Hermes cron job. `hermes backup` already knows what to include and how to copy live SQLite databases safely, so there's no directory sync, thinning or alerting to maintain.

## When to use / when not to

- Use when: Hermes runs under `~/.hermes` on a Mac with an always-running gateway, and you can reach a NAS over SFTP.
- Don't use when: the instance holds data you can't afford to lose. This has no restore test, encryption or alerting.
- Don't use when: the gateway isn't always up. Hermes cron only fires while the gateway runs, so a launchd agent is the likely alternative. [not covered: not built or tested]

Work only on the machine the user asked about. Don't inspect or change other hosts. The NAS is touched only by the rclone commands below.

## The canonical form

`references/hermes-dev-backup.sh`, copied from a working Mac. Install it as `~/.hermes/scripts/hermes-dev-backup.sh`:

```bash
#!/bin/bash
# Daily Hermes backup: keeps 3 zips on this Mac and 14 days on the NAS.
# Silent on success; a failure exits non-zero and shows in `hermes cron list`.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
D="$HOME/Backups/hermes"
R="nas-hermes:/share/ServerBackups/hermes-dev/$(hostname -s)"
mkdir -p "$D"

hermes backup -o "$D/hermes-backup-$(date +%F-%H%M%S).zip" -k 3 >/dev/null || exit 1
rclone copy "$D" "$R" --include 'hermes-backup-*.zip' || exit 1
rclone delete --min-age 14d "$R"
```

Change the remote path in `R` to suit the NAS. `hermes backup -k 3` handles local retention. `rclone copy` never deletes, so zips pruned locally stay on the NAS until they reach 14 days.

## Steps

Replace `<nas-host>` with the NAS's proper DNS name and `<user>` with its SSH user.

1. Confirm the gateway is running: `lsof -nP -iTCP:8642 -sTCP:LISTEN`.
2. Confirm the machine can already log in: `ssh <user>@<nas-host> true`. If it can, reuse its key. Don't generate a new one.
3. Check that key works unattended. This must print `ok`:
   ```bash
   ssh-keygen -y -P '' -f ~/.ssh/id_rsa >/dev/null && echo ok
   ```
4. Make sure `known_hosts` has `<nas-host>`: `ssh-keygen -F <nas-host> -l -f ~/.ssh/known_hosts`. If it doesn't, see the first gotcha.
5. Create a dedicated remote, leaving any existing ones alone:
   ```bash
   rclone config create nas-hermes sftp host=<nas-host> user=<user> \
     key_file="$HOME/.ssh/id_rsa" known_hosts_file="$HOME/.ssh/known_hosts" \
     shell_type=unix --non-interactive
   ```
6. Test the login and parent path: `rclone lsd nas-hermes:<parent-path>`. If the path is wrong, stop and ask.
7. Install the script with mode 755 and run it by hand.
8. Create the job, using cron syntax:
   ```bash
   hermes cron create "0 13 * * *" --name dev-backup \
     --script hermes-dev-backup.sh --no-agent --deliver local
   ```

## Gotchas

- **`knownhosts: key is unknown`:** rclone matches `known_hosts` on the exact hostname in the remote, so a NAS trusted under one name fails under another. Fix `known_hosts`, and don't switch the remote to whichever name happens to be listed. Compare the fingerprints from `ssh-keyscan <nas-host> | ssh-keygen -lf -` with those of the name already trusted (`ssh-keygen -F <trusted-name> -l -f ~/.ssh/known_hosts`), and append the scanned keys only if they match. If nothing is already trusted, have the user confirm the fingerprints. Never disable the check.
- **Use the proper DNS name:** don't use a Tailscale IP or a short name because it's what you found first. Ask if the name isn't clear. A `.home` name only resolves on the home network, which is fine for an always-on desktop but not a laptop.
- **Don't reuse a remote blindly:** an `rclone.conf` copied from Linux can carry a `key_file` under `/home/...`, which doesn't exist on a Mac. Read non-secret fields with `rclone config show <remote> | grep -E '^(host|user|key_file)'`, because the full output can include secrets.
- **Agent-only keys:** `ssh` may log in through an agent such as 1Password while rclone reads `key_file` directly. That's why step 3 tests the file. [not covered: using an agent with this unattended job]
- **Schedule syntax:** use a cron expression, not "every day at 1pm". `hermes cron create --help` documents forms like `30m`, `every 2h` and `0 9 * * *`.
- **Secrets:** the zip holds `.env` and `auth.json` unencrypted. Anyone who can read the NAS folder can read them, so tell the user.
- **Size:** a real instance produced about 152 MB per zip, so 14 days is about 2.1 GB. Measure the first run, as this varies by instance.

## Verify

```bash
R="nas-hermes:<remote-path>/$(hostname -s)"
~/.hermes/scripts/hermes-dev-backup.sh; echo "exit $?"
rclone check ~/Backups/hermes "$R" --include 'hermes-backup-*.zip'   # expect: 0 differences found
python3 -I -c "import sys,zipfile; n=zipfile.ZipFile(sys.argv[1]).namelist(); print([w for w in ('.env','config.yaml','state.db','auth.json') if w not in n] or 'all present')" "$(ls -t ~/Backups/hermes/hermes-backup-*.zip | head -1)"
hermes cron run <job-id>     # expect: Ran now: succeeded
hermes cron list             # expect: Last run ... ok
```

[not covered: restore. No restore from these zips has been tested.]

## References

- `references/hermes-dev-backup.sh`: the working script
- `hermes-macos-launchd`: runs the gateway that fires this job
