# Private AI Stack

Self-hosted private AI chat on your own box: **Ollama + Open WebUI + Caddy
(automatic HTTPS)**. One script, Debian 12/13 or Ubuntu 22.04+.

```bash
git clone https://github.com/docmediadev/private-ai-stack.git && cd private-ai-stack
cp .env.example .env      # set DOMAIN and ACME_EMAIL
sudo ./install.sh
```

The UI is immediately reachable on `http://127.0.0.1:8080` — smoke-test it
before touching DNS. Once your A record for `DOMAIN` points at the box, Caddy
obtains the certificate on its own and serves `https://<your-domain>`. The first
account you create becomes the admin. The installer generates the UI's required
secret key (`WEBUI_SECRET_KEY`) automatically on first run.

## Requirements

- Debian 12/13 or Ubuntu 22.04+, root access
- 4 GB RAM minimum (default model is small and CPU-friendly), 16 GB to be interesting
- A domain name, only if you want public HTTPS

## What is in this repo

`install.sh`, `docker-compose.yml`, `Caddyfile`, `.env.example`. MIT licensed —
use it, fork it, ship it.

## Full pack

The tested version — `verify.sh` smoke test, `HARDENING.md`, `RUNBOOK.md`,
`model-guide.md`, the raw `TESTED.md` evidence log —
is here: **<paid link>**

## Notes that cost me an evening each

- Name the ollama model volume, or every `docker compose up -d` re-downloads your models.
- The restic container needs its target mounted, or it init-loops forever.
- `ufw` default-deny locks you out if sshd listens on a non-standard port;
  `install.sh` detects that port, and `SKIP_FIREWALL=1` skips the step entirely.
- Debugging TLS and debugging compose simultaneously is how you lose a night.
  Bring the stack up on loopback first.
