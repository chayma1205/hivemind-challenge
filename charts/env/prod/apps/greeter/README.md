# greeter (env/prod/apps)

The actual Helm chart for Hivemind's greeter service
([`app/greeter.go`](../../../../app/greeter.go)) — a `Deployment`, `Service`,
optional `Ingress` (ALB), optional `HorizontalPodAutoscaler`, and a
`PodDisruptionBudget`. Unlike the charts under `critical/` and
`central-services/`, this one isn't a wrapper around an upstream chart —
it's ours, templated from scratch.

Lives under `charts/env/prod/apps/` to separate actual application
workloads from cluster-critical add-ons
([`../../critical`](../../critical)) and shared platform services
([`../../central-services`](../../central-services)).

## ⚠️ Won't schedule until general node capacity exists

The cluster's only node group is tainted `CriticalAddonsOnly=true:NoSchedule`
and reserved for the critical/central-services charts (see
`terraform/envs/prod`'s `eks_managed_node_groups.default`). This chart
deliberately does **not** tolerate that taint (see the note at the bottom of
[`values.yaml`](values.yaml)) — app workloads aren't meant to compete with
Argo CD/Karpenter/the ALB controller for that capacity.

Until [Karpenter](../../critical/karpenter) is actually running (which
itself needs the IAM prerequisites listed in its README) and provisioning
general-purpose nodes via its `NodePool`, there is **no untainted capacity
in this cluster** — pods from this chart will stay `Pending`. This isn't a
bug in this chart; it's the intended shape once the platform is fully wired
up, just not yet fully wired up.

## Required values

`image.repository` and `image.tag` have no default and are marked
`required` — an install without them fails immediately instead of silently
pulling nothing. Typically set from CI after a build/push:

```bash
ECR_URL=$(terraform -chdir=../../../../terraform/envs/prod output -raw ecr_repository_url)
TAG=$(git rev-parse --short HEAD)
```

## Install

```bash
cd charts/env/prod/apps/greeter

helm upgrade --install greeter . \
  --namespace greeter --create-namespace \
  --set image.repository="$ECR_URL" \
  --set image.tag="$TAG" \
  --set env.HELLO_TAG="<your-unique-tag>"
```

## Notes

* `HELLO_TAG` is read from the environment at *request* time (see
  `app/greeter.go`), so changing it is a `kubectl set env` / values change
  + rollout — no rebuild needed.
* `ingress.enabled` defaults to `false` for the same reason as the other
  charts' ingress: it needs the ALB controller and a real domain/ACM
  certificate first.
* `autoscaling.enabled` defaults to `false` — the cluster has no
  metrics-server yet (see [`docs/ARCHITECTURE.md`](../../../../docs/ARCHITECTURE.md)'s
  gap list), so an HPA would have no metrics to scale on.
* `topologySpreadConstraints` spreads replicas across AZs
  (`ScheduleAnyway`, so it degrades gracefully rather than blocking
  scheduling outright under constrained capacity).
