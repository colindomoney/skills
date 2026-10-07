---
name: research-crawl4ai-macos-keychain
description: Stop hyperresearch / Crawl4AI fetches from triggering repeated macOS keychain prompts ("Google Chrome for Testing wants to use your confidential information stored in Chromium Safe Storage") and ":9222" CDP connection errors. Use when running /hyperresearch or `hyperresearch fetch` on macOS with provider = "crawl4ai", when editing the [web] section of .hyperresearch/config.toml, before fetching many pages in parallel, or when keychain dialogs, ECONNREFUSED on port 9222, or "Connection closed while reading from the driver" appear.
license: MIT
metadata:
  author: colindomoney
  tags: "research, crawl4ai, hyperresearch, macos, keychain"
  version: "0.1.0"
  last-verified: "2026-10-07"
  status: live   # skeleton | live | dormant
---

# Crawl4AI on macOS without keychain prompts

With `profile` set under `[web]`, hyperresearch's Crawl4AI provider starts a persistent "managed browser" (Chrome for Testing with a saved profile folder). Every launch asks the macOS keychain for the "Chromium Safe Storage" key, and every managed browser shares one fixed debug port (`:9222`). Run several fetchers at once and you get a flood of password dialogs plus connection collisions. Leave `profile` unset and Crawl4AI uses an ephemeral browser instead.

## When to use / when not to

- Use when: provider is `crawl4ai`, the machine is macOS, and you are about to fetch (especially in parallel), or prompts and `:9222` errors have already appeared.
- Don't use when: you genuinely need logged-in pages (LinkedIn, paywalled news). A profile is the only way to keep a login, so accept the prompts for that run and fetch one page at a time, with the user watching. Use the Claude-in-Chrome route (the user's normal browser) for login-gated pages instead.

## The canonical form

In `.hyperresearch/config.toml`, comment out `profile` under `[web]`:

```toml
[web]
provider = "crawl4ai"
# profile = "research"   # disabled: persistent managed browser asks for the "Chromium Safe Storage" keychain item on every launch and shares :9222 between fetchers
magic = true
```

Why it works (hyperresearch `web/crawl4ai_provider.py`): when a profile name resolves to a data directory, the provider sets `use_managed_browser=True` and `user_data_dir=<~/.crawl4ai/profiles/NAME>`. With no profile, neither is set.

## Steps

1. Before any fetch on macOS, read the `[web]` section of `.hyperresearch/config.toml`. If `profile` is set and uncommented, comment it out.
2. Fetch serially, or at most 2 to 3 browsers at a time. Do not spawn the 8 to 12 fetcher subagents the step-2 width sweep defaults to.
3. If any fetcher reports a browser error (`ECONNREFUSED ... :9222`, "Connection closed while reading from the driver", "CDP endpoint ... is not ready"), stop all fetchers immediately and tell the user. Do not retry.
4. Tell the user before the first crawler launch that it may trigger a keychain dialog, and that **Deny** is the safe answer. Never ask for or type their keychain password.

## Gotchas

- **Scale.** The first time this happened the user got a very large number of stacked prompts (uncounted). They were unresponsive: Allow and Deny could not be clicked, buttons were greyed out, Esc did nothing useful.
- **Recovery is unknown.** The prompts only cleared when the machine ran out of memory. No deliberate fix was found. An agent's shell sandbox could not see or kill the browser processes (`ps` showed about 31 processes) and a `killall SecurityAgent` attempt was refused by the permission classifier. Do not promise a fix; prevention is the only reliable approach.
- **Stopping the agents does not stop the browsers.** Killing the fetcher subagents did not visibly stop the prompts.
- **`hyperresearch setup` or a fresh vault can bring the profile back.** `setup` offers to create a login profile. Decline it for public-source research and re-check `[web]` afterwards.
- **Step-2 skill defaults to wide fan-out.** `.claude/skills/hyperresearch-2-width-sweep/SKILL.md` says to spawn 10 to 12 fetchers in one message. That file is rendered from the package template, so a local edit can be overwritten by `hyperresearch install` or `hyperresearch profile use`.
- **`curl` is not a general workaround.** It for most sources: AES returned 403 and a QMUL repository link was dead. Cloudflare-gated pages passed in the user's normal Chrome via Claude-in-Chrome without prompts.

## Verify

Tested once, 2026-10-07: with `profile` commented out, a single fetch finished with no keychain dialog.

```bash
hyperresearch fetch "https://example.com" --tag keychain-test -j
# expect: ok true, provider crawl4ai, about 4 s, and the user sees no dialog
rm research/notes/example-domain.md && hyperresearch sync -j   # remove the test note
```

Not yet verified: several concurrent fetchers with `profile` disabled. Treat parallelism as unsafe on macOS until it has been tested with the user watching.

## References

- Package source: `hyperresearch/web/crawl4ai_provider.py` (`Crawl4AIProvider.__init__`, `user_data_dir` / `use_managed_browser`)
- Project-local note written by the autoharness plugin: `.claude/skills/hyperresearch-macos-crawl4ai-keychain/SKILL.md` (same fix, shorter)
