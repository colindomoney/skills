---
name: hermes-searxng-search
description: Give Hermes Agent free, self-hosted web search by running SearXNG in Docker on loopback and pointing Hermes's web_search backend at it, while web_extract stays on Tavily or Firecrawl. Use when asked to "set up SearXNG", "give Hermes free search", "stop burning Tavily credits", "switch Hermes web search", "set search_backend / extract_backend", when editing the web section of ~/.hermes/config.yaml or SEARXNG_URL in ~/.hermes/.env, or when Hermes web_search returns nothing from SearXNG.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, searxng, docker, tavily, firecrawl, web-search"
  version: "0.1.0"
  last-verified: "2026-10-28"
  status: live
---

# SearXNG as the Hermes web_search backend

Hermes Agent selects web search and web extract separately, via `web.search_backend` and `web.extract_backend` in `~/.hermes/config.yaml`. SearXNG is a self-hosted metasearch engine with a JSON API: it costs no credits, so it takes over `web_search`. It cannot fetch pages, so `web_extract` stays on Tavily or Firecrawl. Pin both keys explicitly, because Hermes otherwise autodetects from whichever provider keys happen to be in `~/.hermes/.env`.

## When to use / when not to

- Use when: setting up or moving Hermes web search to SearXNG, or Tavily credits are running low.
- Don't use when: you need page extraction (SearXNG is search only); Hermes runs somewhere without Docker.

## The canonical form

Deployment folder (e.g. `~/Deployments/SearXNG/`), copied from the running install:

- `references/docker-compose.yml`: image from `ghcr.io`, port bound to `127.0.0.1:8089`, `./config` mounted at `/etc/searxng`, named cache volume, `restart: always`.
- `references/settings.yml`: goes to `config/settings.yml`. Default settings plus the `json` format, limiter and image proxy off.
- `references/.env.example`: `SEARXNG_SECRET`. Copy it to `.env`, and gitignore `.env`.

Hermes, `~/.hermes/config.yaml`:

```yaml
web:
  backend: ''
  search_backend: searxng
  extract_backend: tavily      # or firecrawl
```

Hermes, `~/.hermes/.env` (alongside `TAVILY_API_KEY` or `FIRECRAWL_API_KEY`):

```
SEARXNG_URL=http://127.0.0.1:8089
```

## Steps

1. Create the folder with the three reference files (`settings.yml` under `config/`), and `.gitignore` containing `.env`.
2. `cp .env.example .env` and set `SEARXNG_SECRET` to `openssl rand -hex 32`.
3. `docker compose up -d`.
4. Prove the JSON API on its own before touching Hermes:
   `curl -s 'http://127.0.0.1:8089/search?q=test&format=json' | jq '{n:(.results|length), unresponsive:.unresponsive_engines}'`. `n` must be > 0.
5. Back up `~/.hermes/config.yaml` and `~/.hermes/.env` as `*.bak-<tag>`.
6. Set both `web:` keys in `config.yaml` and add `SEARXNG_URL` to `.env`. Check the key names only; never print values.
7. Restart only the gateway (see `hermes-tmux-stack`).

## Gotchas

- **The JSON API is off by default.** Without `json` in `search.formats`, SearXNG returns 403 to `format=json` and Hermes gets nothing. `references/settings.yml` enables it.
- **Pin both backends.** A pinned `search_backend` or `extract_backend` is used strictly, with no probe or fallback (`tools/web_tools.py`). Leaving them unset autodetects from whatever keys are in `.env`, and adding a key later silently changes the provider.
- **No extract failover.** When Tavily runs out (free tier is 1,000 credits), `web_extract` fails until `extract_backend` is changed and the gateway restarted. Check usage at `https://api.tavily.com/usage` before deciding.
- **Pull from ghcr.io on macOS.** Docker Hub pulls failed on the keychain credential helper. Switching registry avoids it; don't ask the user to unlock the keychain.
- **Loopback only.** Bind `127.0.0.1:8089`. A bare `8089:8080` publishes on every interface, including a public NIC.
- **Upstream engines get blocked.** On 2026-10-28 Brave returned "too many requests" and DuckDuckGo a CAPTCHA, so all results came from Google CSE. Search still worked. Check `unresponsive_engines` in the JSON when results look thin.

## Verify

- `docker ps --filter name=searxng` shows the container up on `127.0.0.1:8089->8080/tcp`.
- The step 4 curl returns `n > 0`.
- After a real Hermes search, `~/.hermes/logs/agent.log` has `plugins.web.searxng.provider: SearXNG search '<query>': N results` followed by `tool web_search completed`.
- Tavily's search count stops rising at `https://api.tavily.com/usage`. Extract is proven only by a real `web_extract` call; say so if it hasn't been exercised.

## References

- `references/docker-compose.yml`, `references/settings.yml`, `references/.env.example`: copied from the running install in `~/Deployments/SearXNG`.
- Hermes source: `tools/web_tools.py` (backend selection), `plugins/web/searxng/provider.py`.
- Related: `hermes-tmux-stack` (restarting the gateway).
