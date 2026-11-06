---
name: hermes-web-search
description: Set up or switch the web search backend for Hermes Agent, prompting for the choice between self-hosted SearXNG in Docker and the Keenable API with an API key. Use when asked to "set up SearXNG", "use Keenable", "add a Keenable key", "give Hermes free search", "stop burning Tavily credits", "switch Hermes web search", "set search_backend / extract_backend", when editing the web section of ~/.hermes/config.yaml, SEARXNG_URL or KEENABLE_API_KEY in ~/.hermes/.env, or when Hermes web_search returns nothing.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, searxng, keenable, docker, tavily, firecrawl, web-search"
  version: "0.2.0"
  last-verified: "2026-11-06"
  status: live
---

# Hermes web search: SearXNG or Keenable

Hermes Agent selects web search and web extract separately, via `web.search_backend` and `web.extract_backend` in `~/.hermes/config.yaml`. This skill sets up one of two search backends. Pin both keys explicitly, because Hermes otherwise autodetects from whichever provider keys happen to be in `~/.hermes/.env`.

| | SearXNG | Keenable |
|---|---|---|
| Runs | Your own Docker container | Hosted API |
| Needs | Docker | API key from keenable.ai |
| Cost | Free | Check keenable.ai for current limits; responses report usage |
| Extract | No, search only | Yes, `web_extract` too |
| Main risk | Upstream engines block it | Queries go to a third party |

## When to use / when not to

- Use when: setting up or moving Hermes web search to either backend.
- Don't use when: you need a chain of backends. Hermes has no such setting (see Gotchas). For restarting the stack, use `hermes-tmux-stack`.

## Start here: ask

Before changing anything, ask the user the following, using the host's question tool if it has one:

1. **Which backend: SearXNG or Keenable?** Use the table above to explain the trade-off. Then follow that path only.
2. **Keenable only: should `web_extract` move to Keenable too, or stay on its current backend?** Keenable extract costs Keenable credits instead of Tavily or Firecrawl credits.

For SearXNG, `extract_backend` must be something else. Keep the existing value, and ask if none is set.

## Before either path

Back up both files. Check key names only; never print values.

```bash
cd ~/.hermes && TAG=$(date +%Y%m%d-%H%M%S)
cp -p config.yaml config.yaml.bak-$TAG && cp -p .env .env.bak-$TAG
sed -n '/^web:/,/^[a-z]/p' config.yaml
grep -oE '^(SEARXNG_URL|KEENABLE_API_KEY|TAVILY_API_KEY|FIRECRAWL_API_KEY)=' .env
```

## Path A: SearXNG in Docker

Deployment folder, e.g. `~/Deployments/SearXNG/`, using the files copied from a running install:

- `references/docker-compose.yml`: image from `ghcr.io`, port bound to `127.0.0.1:8089`, `./config` mounted at `/etc/searxng`, named cache volume, `restart: always`.
- `references/settings.yml`: goes to `config/settings.yml`. Default settings plus the `json` format, limiter and image proxy off.
- `references/.env.example`: `SEARXNG_SECRET`.

1. Create the folder with those three files, and a `.gitignore` containing `.env`.
2. `cp .env.example .env` and set `SEARXNG_SECRET` to the output of `openssl rand -hex 32`. Run `chmod 600 .env`.
3. `docker compose up -d`.
4. Prove the JSON API before touching Hermes. `n` must be above 0:
   ```bash
   curl -s 'http://127.0.0.1:8089/search?q=test&format=json' | jq '{n:(.results|length), unresponsive:.unresponsive_engines}'
   ```
5. Add `SEARXNG_URL=http://127.0.0.1:8089` to `~/.hermes/.env`.
6. Set `~/.hermes/config.yaml`:
   ```yaml
   web:
     backend: ''
     search_backend: searxng
     extract_backend: tavily      # or firecrawl
   ```

## Path B: Keenable with an API key

1. Have the user add `KEENABLE_API_KEY=<key>` to `~/.hermes/.env` themselves, so the key stays out of the chat transcript. If they paste it anyway, use it and tell them it is now in the transcript. Keep the file at mode 600.
2. Prove the key before touching the config. Expect `http=200` and a `results` array:
   ```bash
   K=$(grep -E '^KEENABLE_API_KEY=' ~/.hermes/.env | cut -d= -f2-)
   curl -s -m 30 -w '\nhttp=%{http_code}\n' -X POST https://api.keenable.ai/v1/search \
     -H "Authorization: Bearer $K" -H 'X-Keenable-Title: hermes-agent' \
     -H 'Content-Type: application/json' -d '{"query":"test","max_results":3}' | cut -c1-600
   ```
3. If the user chose Keenable extract, prove that as well. Expect `http=200` and a `content` field:
   ```bash
   curl -s -m 30 -G -w '\nhttp=%{http_code}\n' https://api.keenable.ai/v1/fetch \
     --data-urlencode 'url=https://example.com/' \
     -H "Authorization: Bearer $K" -H 'X-Keenable-Title: hermes-agent' | cut -c1-600
   ```
4. Set `~/.hermes/config.yaml`. Set `extract_backend` to `keenable` only if the user chose that:
   ```yaml
   web:
     backend: ''
     search_backend: keenable
     extract_backend: tavily      # or keenable, or firecrawl
     provider_tier:
       keenable: paid             # fail loudly if the key goes missing
   ```

## Apply the change

Hermes v0.23.0 rereads `config.yaml` by modification time and `.env` by content, so the source indicates a running gateway picks up both changes without a restart. Don't restart it by default. If the verification below shows the old backend still in use, restart only the gateway (see `hermes-tmux-stack`, including its warning about starting a tmux server over SSH).

## Gotchas

- **There is no fallback chain.** A pinned backend is used strictly, and you can't configure a second or third choice. Building one would need a custom web provider plugin.
- **Failed searches can still reach other vendors.** A failed `web_search` gets a one-shot rescue through the keyless vendors (Exa, Parallel, Firecrawl, Keenable), never your other configured backends. Set `web.keyless_rescue: false` to stop it. `tools/web_tools.py` wires this rescue for search only, so don't count on it for extract.
- **A missing Keenable key does not fail by default.** With no key and the tier on auto, Keenable silently runs on its anonymous keyless tier. `web.provider_tier.keenable: paid` makes it raise a missing-key error instead.
- **SearXNG's JSON API is off by default.** Without `json` in `search.formats`, it returns 403 to `format=json` and Hermes gets nothing. `references/settings.yml` enables it.
- **SearXNG can fail silently.** The provider ignores `unresponsive_engines` and reports success even with zero results. Check that field in the JSON when results look thin.
- **SearXNG upstream engines get blocked.** It scrapes other search engines. In October and November 2026, Brave returned "too many requests" and DuckDuckGo a CAPTCHA, so results came almost entirely from Google CSE. Search still worked, but on one engine.
- **SearXNG is search only.** It can't serve `web_extract`, so it always needs a second backend for that.
- **Tavily credits run out.** The free tier is 1,000 credits, and extract uses them even with search elsewhere. Check `https://api.tavily.com/usage` before deciding. Changing backend is the fix once they're gone.
- **Pull from ghcr.io on macOS.** Docker Hub pulls failed on the keychain credential helper. Switching registry avoids it; don't ask the user to unlock the keychain.
- **Bind SearXNG to loopback.** A bare `8089:8080` publishes on every interface, including a public NIC.
- **Don't take the interpreter path from `ls`.** A colour alias can put escape codes in the output. Use `.venv/bin/python` directly.

## Verify

Run a real search through Hermes's own tool code. This doesn't touch the gateway:

```bash
cd ~/.hermes/hermes-agent && .venv/bin/python - <<'E' 2>/dev/null
import json
from tools.web_tools import web_search_tool, _get_search_backend, _get_extract_backend
print("search:", _get_search_backend(), "| extract:", _get_extract_backend())
r = json.loads(web_search_tool("test query", limit=3))
d = r.get("data", {})
print("success:", r.get("success"), "| rescued_from:", d.get("rescued_from"), "| n:", len(d.get("web", [])), "| error:", r.get("error"))
E
```

Expect the chosen backend, `success: True`, `rescued_from: None` and `n` above 0. A `rescued_from` value means your backend failed and another vendor served the search.

Then confirm the gateway, which this test doesn't cover. After the user's next real Hermes search, `~/.hermes/logs/agent.log` should have `Web search via <backend>`. SearXNG also logs `plugins.web.searxng.provider: SearXNG search`. If extract moved, run a real `web_extract` and say so if you couldn't.

## References

- `references/docker-compose.yml`, `references/settings.yml`, `references/.env.example`: copied from a running install.
- Hermes source: `tools/web_tools.py` (backend selection), `tools/web_tools_rescue.py` (rescue), `plugins/web/keyless_mcp.py` (`provider_tier`), `plugins/web/searxng/provider.py`, `plugins/web/keenable/provider.py`.
- Related: `hermes-tmux-stack` (restarting the gateway).
