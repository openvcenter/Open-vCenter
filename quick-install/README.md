# Open vCenter - quick install

One-command, batteries-included deployments of the whole Open vCenter stack,
using the published container images. Pick one:

- **[`docker/`](docker)** - a single `docker-compose.yaml` behind an nginx
  entrypoint (`http://localhost`). Best for a single machine or a quick
  local trial.
- **[`kubernetes/`](kubernetes)** - plain manifests for a k3s single node,
  NodePorts + Traefik Ingress (`*.openvcenter.local`). Best for anything
  that should keep running.

Both auto-import a ready-to-use Keycloak realm (`ovc`, client
`ovc-frontend`) with three test logins:

| Login                   | Group           | What happens                                                            |
| ----------------------- | --------------- | ----------------------------------------------------------------------- |
| `admin` / `admin`       | `ADMINISTRATOR` | Full access.                                                            |
| `operator` / `operator` | `MANAGE_VMS`    | Logs in to an empty tree until a permission is granted to `MANAGE_VMS`. |
| `noroles` / `noroles`   | *(none)*        | Redirected to `/access-denied`.                                         |

These are for kicking the tyres - see each folder's README for how to
change them, and [Access control](https://openvcenter.com/docs/kubernetes/#access-control) for what the app
actually does with a group once you're past login.

## How this relates to the docs

The [Docker Compose](https://openvcenter.com/docs/docker-compose/) and
[Kubernetes](https://openvcenter.com/docs/kubernetes/) docs explain *why* the stack is configured the
way it is; the two folders here are the ready-to-run version, with the realm
import, a generated session secret and a working VM Console tab already wired
up. Each folder's own README lists what it sets up, and why.
