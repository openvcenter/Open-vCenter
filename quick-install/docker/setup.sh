#!/usr/bin/env bash
#
# setup.sh - write .env for the Docker Compose quick install.
#
# Asks one question: the hostname or IP that browsers AND your Hyper-V hosts use
# to reach this machine. Every URL the stack needs is derived from it:
#
#   OVC_PUBLIC_URL          http://<host>         the app (nginx on :80)
#   OVC_KEYCLOAK_URL        http://<host>:8080    Keycloak, as the browser sees it
#   OVC_AGENT_RABBITMQ_URL  amqp://<host>:5672/   what Hyper-V host agents connect to
#   BETTER_AUTH_SECRET      random, generated once and kept on re-runs
#
#   ./setup.sh                 interactive (default: localhost)
#   ./setup.sh --host 10.0.0.5 non-interactive
#   ./setup.sh --defaults      non-interactive, localhost
#
# Re-running rewrites .env but keeps the existing BETTER_AUTH_SECRET. The
# Keycloak realm is imported only on first boot, so after changing the host on
# an existing install, run ./down.sh --purge and ./up.sh (or edit the
# ovc-frontend client's redirect URIs in the Keycloak admin console).
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HOST=""
case "${1:-}" in
  --host) HOST="${2:?--host needs a value}" ;;
  --defaults) HOST="localhost" ;;
  "") ;;
  *) echo "usage: $0 [--host <hostname-or-ip> | --defaults]" >&2; exit 2 ;;
esac

current() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -1 || true; }

if [ -z "$HOST" ]; then
  previous="$(current OVC_HOST)"
  default="${previous:-localhost}"
  if [ -t 0 ]; then
    cat <<EOF
Which hostname or IP do browsers and your Hyper-V hosts use to reach this machine?
  - "localhost" works only for a browser on this machine and no real Hyper-V hosts.
  - For a real setup use this machine's DNS name or LAN IP.
EOF
    read -r -p "Host [$default]: " HOST
  fi
  HOST="${HOST:-$default}"
fi

# Strip a scheme / path / port the user may have pasted.
HOST="${HOST#http://}"; HOST="${HOST#https://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"
if ! [[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "error: '$HOST' is not a valid hostname or IP." >&2
  exit 1
fi

SECRET="$(current BETTER_AUTH_SECRET)"
if [ -z "$SECRET" ]; then
  SECRET="$(openssl rand -hex 32)"
fi

cat > .env <<EOF
# Written by setup.sh - re-run it to change the host.
OVC_HOST=$HOST
OVC_PUBLIC_URL=http://$HOST
OVC_KEYCLOAK_URL=http://$HOST:8080
OVC_AGENT_RABBITMQ_URL=amqp://$HOST:5672/
BETTER_AUTH_SECRET=$SECRET
EOF

echo "==> wrote .env for host '$HOST'"
echo "    app:      http://$HOST"
echo "    keycloak: http://$HOST:8080"
echo "    agents:   amqp://$HOST:5672/"
