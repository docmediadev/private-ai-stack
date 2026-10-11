#!/usr/bin/env bash
# Private AI Stack — bootstrap installer (Debian 12/13, Ubuntu 22.04+)
# Idempotent: safe to re-run. Verified on fresh minimal Debian 13 (see TESTED.md).
set -euo pipefail

log() { printf '[private-ai-stack] %s\n' "$*"; }
die() { printf '[private-ai-stack] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (or with sudo)"

log "checking OS"
# shellcheck source=/dev/null
. /etc/os-release
if ! grep -qiE 'debian|ubuntu' /etc/os-release && [ "${FORCE_OS:-0}" != "1" ]; then
  die "this pack targets Debian/Ubuntu. It may still work elsewhere — re-run with FORCE_OS=1 to continue anyway."
fi
log "os: ${PRETTY_NAME:-unknown}"

log "installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg ufw >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker from the official repo"
  install -m 0755 -d /etc/apt/keyrings
  # The repo URL is per-distro: Debian and Ubuntu are NOT interchangeable here.
  case "${ID:-}" in
    debian) DOCKER_DISTRO=debian ;;
    ubuntu) DOCKER_DISTRO=ubuntu ;;
    *) die "unsupported distro '${ID:-unknown}' for the Docker repo — install Docker manually (https://docs.docker.com/engine/install/) and re-run" ;;
  esac
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
else
  log "docker present: $(docker --version)"
fi

# fail2ban with an sshd jail — HARDENING.md references it; install it here so
# the claim is true out of the box.
if ! command -v fail2ban-client >/dev/null 2>&1; then
  log "installing fail2ban (sshd jail)"
  apt-get install -y -qq fail2ban >/dev/null || log "WARNING: fail2ban install failed — see HARDENING.md §3"
fi
if command -v fail2ban-client >/dev/null 2>&1; then
  if ! fail2ban-client status sshd >/dev/null 2>&1; then
    printf '[sshd]\nenabled = true\nmaxretry = 4\nbantime = 1h\n' > /etc/fail2ban/jail.d/sshd.local
    systemctl enable --now fail2ban >/dev/null 2>&1 \
      || service fail2ban start >/dev/null 2>&1 \
      || log "WARNING: fail2ban installed but could not be started — see HARDENING.md §3"
  fi
fi

if [ ! -f .env ]; then
  log "creating .env from template — EDIT IT (DOMAIN, ACME_EMAIL) before going live"
  cp .env.example .env
fi
# shellcheck source=/dev/null
. ./.env

# Open WebUI 0.5.x+ refuses to start without a secret key. Generate one if
# the template left it blank, so a fresh install boots on the first try.
if [ -z "${WEBUI_SECRET_KEY:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
  else
    WEBUI_SECRET_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  printf 'WEBUI_SECRET_KEY=%s\n' "$WEBUI_SECRET_KEY" >> .env
  log "generated WEBUI_SECRET_KEY in .env"
fi

# sshd -T needs root and a running sshd; fall back to parsing sshd_config,
# then to the common non-22 ports, so a missing binary never locks anyone out.
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
if [ -z "${SSH_PORT:-}" ]; then
  SSH_PORT="$(awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
fi
if [ -z "${SSH_PORT:-}" ]; then
  for p in 22 2222 2200 2022; do
    if ss -tln 2>/dev/null | grep -q ":${p} "; then SSH_PORT="$p"; break; fi
  done
fi
SSH_PORT="${SSH_PORT:-22}"

configure_firewall() {
  ufw --force default deny incoming >/dev/null
  ufw --force default allow outgoing >/dev/null
  ufw allow "${SSH_PORT}/tcp" >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
}

if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
  log "firewall: skipped (SKIP_FIREWALL=1)"
elif configure_firewall; then
  log "firewall: default deny in, ssh(${SSH_PORT})/http/https allowed"
else
  # Never let the firewall decide whether the stack installs. Seen on hosts with
  # an existing nftables setup or inside containers.
  log "WARNING: ufw could not be configured here — the stack is unaffected, but"
  log "         check your firewall by hand (open 22, 80, 443) or set SKIP_FIREWALL=1"
fi

log "starting the stack"
docker compose pull -q
docker compose up -d

log "waiting for the chat UI on 127.0.0.1:8080 (can take ~60s on first boot)"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:8080/health" 2>/dev/null; then
    log "chat UI is up"; break
  fi
  [ "$i" -eq 60 ] && log "WARNING: UI not answering yet — check: docker compose logs -f open-webui"
  sleep 2
done

log "pulling the default model ${OLLAMA_MODEL:-llama3.2:3b} (skip with SKIP_MODEL=1)"
if [ "${SKIP_MODEL:-0}" != "1" ]; then
  docker compose exec -T ollama ollama pull "${OLLAMA_MODEL:-llama3.2:3b}" \
    || log "WARNING: model pull failed (network/proxy?) — retry later: docker compose exec ollama ollama pull ${OLLAMA_MODEL:-llama3.2:3b}"
fi

cat <<EOF

Done. Two things left:

  1. DNS: point ${DOMAIN} at this server, then edit .env if needed and run
         docker compose up -d
     Caddy fetches the certificate on its own; watch it with
         docker compose logs -f caddy
  2. Open https://${DOMAIN} — the first account you create becomes the admin.

Smoke test:  ./verify.sh
Health:      docker compose ps
Logs:        docker compose logs -f caddy
EOF
