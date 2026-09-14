# argocd (env/prod/central-services)

Wrapper chart that installs [Argo CD](https://argo-cd.readthedocs.io/) into
the EKS cluster provisioned by [`terraform/envs/prod`](../../../../terraform/envs/prod).
Argo CD is treated as a central/shared service for this cluster — one
install, not one per workload — hence its home under
`charts/env/prod/central-services/` alongside other cluster-wide add-ons
(e.g. the ALB controller, Karpenter — see [`charts/env/prod/critical`](../../critical)).

It's a thin wrapper around the upstream
[`argo/argo-cd`](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
chart (pinned in [`Chart.yaml`](Chart.yaml)); [`values.yaml`](values.yaml)
only overrides what's needed for this cluster — everything else uses the
upstream chart's defaults.

## Install

```bash
cd charts/env/prod/central-services/argocd
helm dependency update

helm upgrade --install argocd . \
  --namespace argocd --create-namespace \
  -f values.yaml
```

## Access

Ingress is disabled by default (see the `TODO` in `values.yaml`) since it
depends on the ALB controller and a real domain/ACM certificate. Until
those exist, port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Rotate it after first login (`argocd account update-password`).

## Notes

* `server.insecure: true` — the server serves plain HTTP internally; TLS is
  expected to terminate at the ALB once ingress is enabled. Don't expose
  the service directly without a TLS-terminating layer in front of it.
* `rbac.policy.default: role:readonly` — new/unlisted users get read-only
  access by default; grant write access explicitly per team/user rather
  than widening the default.
* This chart only installs Argo CD itself. What Argo CD *manages* (the
  critical add-ons, the greeter app) is defined separately as Argo CD
  `Application` resources — not yet present in this repo.
