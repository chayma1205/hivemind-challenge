# vertical-pod-autoscaler (env/prod/critical)

Wrapper chart that installs the
[Kubernetes Vertical Pod Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
(recommender, updater, admission controller, and their CRDs) into the
`hivemind-prod` EKS cluster — the prerequisite for any workload's own
`VerticalPodAutoscaler` object (e.g.
[`charts/env/prod/apps/greeter`](../../apps/greeter)'s, see that chart's
`values.yaml`).

Lives under `charts/env/prod/critical/` for the same reason as
[`../karpenter`](../karpenter): cluster-scoped, one per cluster, pinned
to the system node group.

## What each component does

* **recommender** — watches pods' actual CPU/memory usage over time and
  computes a recommendation per `VerticalPodAutoscaler` object. Read-only;
  never changes anything on its own.
* **updater** — for a VPA in `Auto`/`Recreate` mode, evicts pods whose
  current resources are far enough from the recommendation to warrant a
  restart. No-op for any VPA left in `Off` mode (recommendation-only).
* **admission controller** — for a VPA in `Auto`/`Initial`/`Recreate`
  mode, mutates a *new* pod's resource requests/limits at creation time
  to match the current recommendation. Also a no-op for `Off` mode.

All three are installed and left running even though the only VPA that
exists right now (greeter's) starts in `updateMode: "Off"` — turning a
future VPA fully on is then just a values change, not a re-install of
this chart.

## Prerequisite

None — unlike this repo's other `critical/` charts, VPA needs no
IAM/IRSA/Pod Identity role. It only reads in-cluster metrics
(`metrics-server`, already an EKS addon) and acts on pods directly.

## Install

```bash
cd charts/env/prod/critical/vertical-pod-autoscaler
helm dependency update

helm upgrade --install vertical-pod-autoscaler . \
  --namespace kube-system \
  -f values.yaml
```

## Notes

* `crds.enabled: true` installs `VerticalPodAutoscaler` and
  `VerticalPodAutoscalerCheckpoint` via a Helm-managed Job rather than
  the chart's special `crds/` directory, which Argo CD's Helm rendering
  doesn't apply — see that value's comment in `values.yaml`.
* Deliberately **not** paired with greeter's HPA on the same metric:
  greeter's `HorizontalPodAutoscaler` scales on CPU, and running an
  *active* (`Auto`) VPA on CPU for the same workload at the same time is
  a well-known anti-pattern — the two controllers can fight each other,
  each reacting to the other's changes. Greeter's VPA stays
  recommendation-only (`updateMode: "Off"`) specifically to avoid that;
  see `charts/env/prod/apps/greeter/values.yaml`.
* `admissionController.replicaCount: 2` for HA (the chart's own default
  is 1) — a single replica being down would mean new pods launch with
  whatever resources they were given in the chart, silently skipping the
  VPA-recommended values, rather than failing loudly.
