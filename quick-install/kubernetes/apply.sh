#!/usr/bin/env bash
#
# apply.sh - deploy Open vCenter to a k3s cluster in one shot:
#
#   postgres 17 / rabbitmq / valkey / keycloak (postgres-backed, "ovc" realm
#   auto-imported) / guacd / backend+worker / frontend
#
# All resources live in the "ovc-infra" namespace. Services are NodePort (no
# LoadBalancer assumed). Data is on ReadWriteOnce PVCs (k3s local-path).
# See README.md before running this on anything but a throwaway lab cluster.
#
# Host names: the manifests use frontend. / keycloak. / rabbitmq[-management].openvcenter.local.
# The first run asks for a base domain (default openvcenter.local) and replaces
# it at apply time; the answer is kept in the ovc-install ConfigMap and reused.
#
#   ./apply.sh                          interactive
#   ./apply.sh --domain lab.example.com non-interactive
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DOMAIN=""
case "${1:-}" in
  --domain) DOMAIN="${2:?--domain needs a value}" ;;
  "") ;;
  *) echo "usage: $0 [--domain <base-domain>]" >&2; exit 2 ;;
esac

kubectl apply -f 00-namespace.yaml

if [ -z "$DOMAIN" ]; then
  previous="$(kubectl -n ovc-infra get configmap ovc-install -o jsonpath='{.data.DOMAIN}' 2>/dev/null || true)"
  default="${previous:-openvcenter.local}"
  if [ -t 0 ] && [ -z "$previous" ]; then
    cat <<EOF
Base domain for the host names: frontend.<domain>, keycloak.<domain> and
rabbitmq-management.<domain> (Ingress), plus rabbitmq.<domain> (agents, NodePort
30672). Browsers and Hyper-V hosts must resolve them to a node IP (DNS or hosts
file).
EOF
    read -r -p "Domain [$default]: " DOMAIN
  fi
  DOMAIN="${DOMAIN:-$default}"
fi
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "error: '$DOMAIN' is not a valid domain." >&2
  exit 1
fi
kubectl -n ovc-infra create configmap ovc-install --from-literal=DOMAIN="$DOMAIN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "==> domain: $DOMAIN"

# Apply a folder with the default domain replaced by the chosen one.
apply_dir() {
  for f in "$1"/*.yaml; do
    echo "---"
    sed "s/openvcenter\.local/$DOMAIN/g" "$f"
  done | kubectl apply -f -
}

# BETTER_AUTH_SECRET is a session-signing key, not a shared default - unlike
# every other value here it doesn't belong in a checked-in ConfigMap.
# Generate one on first apply and keep reusing it (re-running this script
# never rotates it).
if ! kubectl -n ovc-infra get secret ovc-frontend-secret >/dev/null 2>&1; then
  echo "==> generating ovc-frontend-secret (BETTER_AUTH_SECRET)"
  kubectl -n ovc-infra create secret generic ovc-frontend-secret \
    --from-literal=BETTER_AUTH_SECRET="$(openssl rand -hex 32)"
fi

for svc in ovc-postgres ovc-rabbitmq ovc-valkey ovc-keycloak ovc-guacd ovc-backend ovc-frontend; do
  echo "==> applying $svc"
  apply_dir "$svc"
done

echo
echo "==> waiting for deployments to become available..."
kubectl -n ovc-infra rollout status deploy/ovc-postgres       --timeout=180s
kubectl -n ovc-infra rollout status deploy/ovc-rabbitmq       --timeout=180s
kubectl -n ovc-infra rollout status deploy/ovc-valkey         --timeout=120s
kubectl -n ovc-infra rollout status deploy/ovc-keycloak       --timeout=300s || true
kubectl -n ovc-infra rollout status deploy/ovc-guacd          --timeout=120s
kubectl -n ovc-infra rollout status deploy/ovc-backend        --timeout=180s
kubectl -n ovc-infra rollout status deploy/ovc-backend-worker --timeout=180s
kubectl -n ovc-infra rollout status deploy/ovc-frontend       --timeout=120s

# Sign-in check: the frontend pod must reach Keycloak's discovery document,
# and Keycloak must report the browser-facing issuer.
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
  if out="$(kubectl -n ovc-infra exec deploy/ovc-frontend -- node -e "$CHECK_JS" 2>&1)"; then
    ok=1
    break
  fi
  sleep 10
done
if [ -n "$ok" ]; then
  echo "    OK - frontend reaches Keycloak; issuer is http://keycloak.$DOMAIN/realms/ovc"
else
  echo "    FAIL - $out" >&2
  echo "    Look at: kubectl -n ovc-infra logs deploy/ovc-keycloak; kubectl -n ovc-infra logs deploy/ovc-frontend" >&2
fi

echo
echo "==> ingress hosts (point each at the node IP - see README \"Ingress\"):"
kubectl -n ovc-infra get ingress

cat <<EOF

Test logins (realm "ovc", client "ovc-frontend"):
  admin/admin        - ADMINISTRATOR (full access)
  operator/operator  - MANAGE_VMS   (login only - no scope granted yet, sees nothing)
  noroles/noroles    - no role      (redirected to /access-denied)

Open http://frontend.$DOMAIN once DNS/hosts resolves it, or
http://<node-ip>:30300 directly (NodePort) - see README for the redirect_uri
caveat on that second path.
EOF

kubectl -n ovc-infra get pods,svc
