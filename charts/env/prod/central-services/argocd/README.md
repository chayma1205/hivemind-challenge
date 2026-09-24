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

## Repository access (private repo)

This repo is private (revisited in docs/DECISIONS.md #10 — it was public
until the greeter app's source moved out to its own repo). Argo CD's
repo-server needs a credential to clone it, and
[`charts/env/prod/argocd-apps.yaml`](../../argocd-apps.yaml) is generated
with SSH-style `repoURL`s (`git@github.com:chayma1205/hivemind-challenge.git`)
to match.

A **read-only** SSH deploy key is registered on the repo for this
purpose (`Settings -> Deploy keys`, no write access — repo-server only
ever needs to clone). Register it as a repository credential Argo CD
auto-discovers, one-time manual bootstrap step (see docs/DECISIONS.md #10
on why this stays a human action rather than something a pipeline or
agent creates):

```bash
kubectl -n argocd create secret generic hivemind-challenge-repo-creds \
  --from-literal=type=git \
  --from-literal=url=git@github.com:chayma1205/hivemind-challenge.git \
  --from-file=sshPrivateKey=/path/to/read_only_key
kubectl -n argocd label secret hivemind-challenge-repo-creds \
  argocd.argoproj.io/secret-type=repository
```

Separately, [`../argocd-image-updater`](../argocd-image-updater) needs
its **own** key with **write** access for its git write-back (a
read-only key can't push) — see that chart's README.

## Access

ALB-fronted at `argocd.hivemind.chaima.online` (`server.ingress` in
`values.yaml`) — see that value's own comment for how TLS is wired. For
local access without going through the ALB:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Rotate it after first login (`argocd account update-password`).

## Notifications

The notifications controller (`argo-cd.notifications` in `values.yaml`)
pushes into the Alertmanager the
[`kube-prometheus-stack`](../kube-prometheus-stack) chart installs — not
a separate Slack/email/webhook integration. Two global subscriptions
(applying to every Application, no per-chart annotation needed):

* **`on-out-of-sync`** — a custom trigger (not in Argo CD's own built-in
  catalog, which covers `on-sync-status-unknown` but has no OutOfSync
  equivalent). Fires once per transition into `OutOfSync`.
* **`on-health-degraded`** — Argo CD's built-in trigger; this chart just
  overrides its template to add the `alertmanager:` block the stock
  template doesn't have.

This exists specifically to close a real, twice-recurring near-miss
(`docs/ASSESSMENT.md` bugs 6 and 7): a live `kubectl` fix silently
reverted by `selfHeal` because it wasn't pushed to git yet, caught both
times only because someone happened to check afterward. An Application
briefly going `OutOfSync` is exactly what that revert looks like from
the outside — now it pages instead of waiting to be noticed.

**Known tradeoff, not a bug**: `on-out-of-sync` also fires on ordinary,
expected syncs (any git-triggered deploy briefly shows `OutOfSync` before
`selfHeal` reconciles it), so expect one notification per routine deploy
alongside genuine drift-revert catches. Also, because this pushes a
one-shot alert into Alertmanager rather than a continuously-scraped
metric, Alertmanager's own `resolve_timeout` (5m) will mark it resolved
on a timer regardless of whether the underlying condition actually
cleared — a "RESOLVED" email 5 minutes later doesn't necessarily mean
anything was fixed, just that the alert aged out.

## Notes

* `server.insecure: true` — the server serves plain HTTP internally; TLS is
  expected to terminate at the ALB once ingress is enabled. Don't expose
  the service directly without a TLS-terminating layer in front of it.
* `rbac.policy.default: role:readonly` — new/unlisted users get read-only
  access by default; grant write access explicitly per team/user rather
  than widening the default.
* This chart only installs Argo CD itself. What Argo CD *manages* (the
  critical add-ons, the greeter app) is defined separately as Argo CD
  `Application` resources in
  [`charts/env/prod/argocd-apps.yaml`](../../argocd-apps.yaml)
  (generated by [`scripts/generate-argocd-apps.sh`](../../../../../scripts/generate-argocd-apps.sh)).
