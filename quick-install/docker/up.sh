#!/usr/bin/env bash
#
# up.sh - bring up Open vCenter (published images) behind a single nginx
# entrypoint on port 80:
#
#   postgres 17 / rabbitmq / valkey / guacd / keycloak (postgres-backed,
#   "ovc" realm auto-imported) / guacd / backend + worker / frontend / nginx
#
# First run calls ./setup.sh, which asks which host browsers and Hyper-V hosts
# use to reach this machine and writes .env.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: 'docker' not found. Install Docker: https://www.docker.com/products/docker-desktop/" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not running." >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "error: 'docker compose' not available." >&2
  exit 1
fi

# .env holds the host-derived URLs and the generated BETTER_AUTH_SECRET.
# setup.sh asks for the host the first time; re-run it to change the host.
if ! grep -q '^OVC_HOST=' .env 2>/dev/null; then
  ./setup.sh
fi
# shellcheck disable=SC1091
source .env

echo "==> pulling images..."
"${COMPOSE[@]}" pull

echo "==> starting containers..."
"${COMPOSE[@]}" up -d

echo
echo "==> status:"
"${COMPOSE[@]}" ps

# Sign-in check: the frontend container must reach Keycloak's discovery
# document, and Keycloak must report the browser-facing issuer. ovc-frontend
# only starts once Keycloak is healthy, so this normally passes at once.
echo
echo "==> checking sign-in configuration..."
CHECK_JS='
const want = process.env.OIDC_ISSUER;
fetch(process.env.OIDC_INTERNAL_URL + "/.well-known/openid-configuration")
  .then((r) => r.json())
  .then((d) => {
    if (d.issuer !== want) { console.log("issuer is " + d.issuer + ", expected " + want); process.exit(1); }
    if (!d.authorization_endpoint.startsWith(want)) { console.log("authorization_endpoint " + d.authorization_endpoint + " is not browser-facing"); process.exit(1); }
  })
  .catch((e) => { console.log("discovery fetch failed: " + (e.cause?.code || e.message)); process.exit(1); });
'
ok=""
for _ in $(seq 1 30); do
  if out="$("${COMPOSE[@]}" exec -T ovc-frontend node -e "$CHECK_JS" 2>&1)"; then
    ok=1
    break
  fi
  sleep 5
done
if [ -n "$ok" ]; then
  echo "    OK - frontend reaches Keycloak; issuer is ${OVC_KEYCLOAK_URL}/realms/ovc"
else
  echo "    FAIL - $out" >&2
  echo "    Look at: docker compose logs ovc-keycloak ovc-frontend" >&2
fi

cat <<EOF

Open vCenter:  ${OVC_PUBLIC_URL}
  test logins (realm "ovc", client "ovc-frontend"):
    admin/admin        - ADMINISTRATOR (full access)
    operator/operator  - MANAGE_VMS   (login only - no scope granted yet, sees nothing)
    noroles/noroles    - no role      (redirected to /access-denied)

Other services:
  keycloak admin console   ${OVC_KEYCLOAK_URL}         (admin/admin)
  rabbitmq management      http://${OVC_HOST}:15672        (ovc/PleaseChangeMe1)
  backend direct/Swagger   http://${OVC_HOST}:8000/api/docs

Logs:  docker compose logs -f
Stop:  ./down.sh
EOF
