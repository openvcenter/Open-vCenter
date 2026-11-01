# Open vCenter - Docker Compose quick install

The whole stack as one `docker-compose.yaml` with the published images,
everything behind a single **nginx** entrypoint on port 80 instead
of separate per-service ports for the app itself. See
[Docker Compose](https://openvcenter.com/docs/docker-compose/) for the reasoning behind the setup.
What's wired up:

- **nginx as the "ingress"** - one public entrypoint (`:80`) routing `/api/`
  to `ovc-backend` and everything else to `ovc-frontend`, the same
  single-domain pattern documented in `ovc-frontend/README.md`'s nginx
  sketch, so Keycloak's `redirect_uri`, `OVC_CORS_ORIGINS` and
  `OVC_PUBLIC_BASE_URL` only ever have to agree on one origin.
- **Keycloak is Postgres-backed with the `ovc` realm auto-imported** on
  first boot (`keycloak/ovc-realm.json`) - no manual realm/client creation,
  and it survives a `docker compose down` / `up` cycle.
- **One question, every URL** - `setup.sh` (called by `up.sh` on first run)
  asks which hostname or IP browsers and Hyper-V hosts use to reach this
  machine and writes `.env`: `OVC_PUBLIC_URL`, `OVC_KEYCLOAK_URL`,
  `OVC_AGENT_RABBITMQ_URL`, plus a generated `BETTER_AUTH_SECRET` (never a
  fixed value in a public repo). The compose file and the realm import read
  them from there.
- **Sign-in works from inside containers** - the browser reaches Keycloak at
  `OVC_KEYCLOAK_URL`, but inside `ovc-frontend` "localhost" is the container
  itself. So Keycloak pins its issuer with `KC_HOSTNAME` (plus
  `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` for server-to-server URLs), and
  `ovc-frontend` fetches discovery from `http://ovc-keycloak:8080`
  (`OIDC_INTERNAL_URL`). `ovc-frontend` starts only once Keycloak is healthy,
  and `up.sh` ends with a sign-in check from inside the frontend container.
- **nginx survives container restarts** - it re-resolves service names through
  Docker's DNS, and its header buffers fit better-auth's cookie-mode session.
- **Consoles need only `guacd`** - `ovc-frontend` serves the Guacamole
  tunnel itself and reaches `ovc-guacd` over the internal Compose network
  (`GUACD_URL: ovc-guacd:4822`). guacd publishes no port: the browser never
  talks to it.
- **`OVC_PUBLIC_BASE_URL` is set** - without it, the Setup Agent one-liner /
  agent binary downloads fail outright with `OVC_AGENT_STORAGE=local`.

## Bring it up

```sh
./up.sh
```

The first run asks for the host (default `localhost`, which only suits a
browser on this machine and no real Hyper-V hosts - use the machine's DNS name
or LAN IP otherwise). Open `http://<host>` and log in with one of the realm's
test users (see below). Tear down with `./down.sh` (`--purge` also drops the
data volumes and `.env`).

To change the host later, run `./setup.sh` (or `./setup.sh --host <name>`) and
then `./up.sh`. Keycloak imports the realm only on first boot, so either
`./down.sh --purge` first or update the `ovc-frontend` client's redirect URIs
in the Keycloak admin console.

## Roles / test logins

| Login                   | Role            | What happens                                                                                                             |
| ----------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `admin` / `admin`       | `ADMINISTRATOR` | Full access to every cluster/host/folder/VM.                                                                             |
| `operator` / `operator` | `MANAGE_VMS`    | Logs in, sees nothing until a scope grant is added (no admin UI for that yet - it's a `ScopeGrant` row in the database). |
| `noroles` / `noroles`   | _(none)_        | Redirected to `/access-denied`.                                                                                          |

See [Roles](https://openvcenter.com/docs/kubernetes/#roles) for what each role actually
grants. Change or remove these test users once you're past a first login -
they're plain-text in `keycloak/ovc-realm.json`.

## Layout

```
docker-compose.yaml    everything: backing services, keycloak, guacd,
                        backend + worker, frontend, nginx
init-db/01-keycloak.sql   creates the "keycloak" DB on Postgres's first boot
keycloak/ovc-realm.json   the "ovc" realm, imported automatically
nginx/nginx.conf          the single entrypoint (:80 -> frontend / backend)
setup.sh                  asks for the host, writes .env
up.sh / down.sh
```

## Ports

| Service             | Port   | Notes                                               |
| ------------------- | ------ | --------------------------------------------------- |
| **nginx (the app)** | **80** | **This is what you open in a browser.**             |
| postgres            | 5432   |                                                     |
| rabbitmq AMQP       | 5672   |                                                     |
| rabbitmq management | 15672  | web UI, `ovc` / `PleaseChangeMe1`                   |
| valkey              | 6379   |                                                     |
| keycloak            | 8080   | admin console (`admin`/`admin`) + `ovc` realm       |
| backend (direct)    | 8000   | REST API, Swagger at `/api/docs`                    |
| frontend (direct)   | 3000   | debug only - login here fails, see below            |

`frontend` and `backend` stay published on their own ports too, for `curl`
and Swagger - but **log in through `http://<host>` (nginx), not
`:3000`**: the imported realm only registers `http://<host>/*` and
`http://localhost:3000/*` as redirect URIs, and `BETTER_AUTH_URL` /
`OVC_PUBLIC_BASE_URL` are both pinned to the nginx origin, so a session
started on `:3000` will misbehave past the login screen.

## Notes

- **Postgres**: uses the official `postgres:17` image with a named volume
  (`pgdata`), so no `PGDATA` workaround is needed. The `keycloak` database
  is created on first boot by `init-db/01-keycloak.sql`.
- **RabbitMQ**: `hostname: ovc-rabbitmq` pins the Erlang node name so a
  `docker compose up` after a `down` (not `down -v`) keeps the same Mnesia
  DB (users, permissions, vhosts, durable queues).
- **Keycloak**: `--import-realm` only runs on first boot (i.e., against an
  empty `keycloak` database). Edit the client by hand in the admin console
  afterwards, or `./down.sh --purge` and `./up.sh` again to re-trigger the
  import (loses all Postgres data, not just Keycloak's).
- **Agent RabbitMQ URL**: `OVC_AGENT_RABBITMQ_URL` comes from the host
  given to `setup.sh` (`amqp://<host>:5672/`). With `localhost` it only works
  for an agent on this same machine; real Hyper-V hosts need the Docker host's
  LAN-reachable name or IP. You can also edit it in `.env` directly and run
  `docker compose up -d ovc-backend`.
- **backend / frontend**: published as **public** GHCR images
  (`ghcr.io/openvcenter/ovc-backend`, `ovc-frontend`) - no registry
  login needed to pull them.
- **guacd** (`ovc-guacd`, no published port): `GUACD_URL` on `ovc-frontend`
  is read at runtime on every console connection (`host:port`, or
  `scheme://host:port` with the scheme ignored). guacd has to resolve and
  reach your Hyper-V hosts (2179 / 3389) - add `extra_hosts` to `ovc-guacd`
  if their names aren't in DNS.
