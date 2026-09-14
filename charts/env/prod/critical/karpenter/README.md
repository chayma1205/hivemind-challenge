# karpenter (env/prod/critical)

Wrapper chart that installs [Karpenter](https://karpenter.sh/) for node
autoscaling in the `hivemind-prod` EKS cluster, plus a default
`NodePool`/`EC2NodeClass` pair so it can actually launch nodes once
installed.

It lives under `charts/env/prod/critical/` (not `central-services/`)
because it's cluster-scoped configuration tied to *this* environment's
cluster name, subnets and node role — unlike Argo CD, which is installed
once per cluster with no per-env values.

## Prerequisites

Provisioned by `terraform/envs/prod`'s `module.karpenter`
(`terraform-aws-modules/eks/aws//modules/karpenter`, with `enable_irsa =
true` since this module defaults to the newer Pod Identity mechanism, not
classic IRSA) and wired into [`values.yaml`](values.yaml):

1. **Controller IRSA role** — `karpenter.serviceAccount.annotations."eks.amazonaws.com/role-arn"`,
   from the `karpenter_iam_role_arn` output.
2. **Node IAM role** — `nodePool.nodeRoleName`, from `karpenter_node_iam_role_name`.
   `iam_role_use_name_prefix`/`node_iam_role_use_name_prefix` are set to
   `false` in Terraform so these names (and the hardcoded ARN above) stay
   stable across applies instead of getting a random suffix each time the
   role is replaced.
3. **Interruption queue** — `karpenter.settings.interruptionQueue`, from
   `karpenter_interruption_queue_name` (`enable_spot_termination = true`
   provisions the SQS queue + EventBridge rules even though the default
   `NodePool` only uses on-demand capacity — harmless, and one less thing
   to wire up later if that changes).

## ⚠️ One prerequisite still missing

**Discovery tags** — Karpenter finds subnets and the node security group by
tag (`karpenter.sh/discovery = hivemind-prod` by default here, see
[`templates/nodeclass.yaml`](templates/nodeclass.yaml)). This tag isn't yet
applied to the VPC module's private subnets or the EKS node security group
in `terraform/envs/prod` — add it there before this chart's `NodePool` can
actually launch anything. Until then, `helm install` succeeds and the
controller runs, but any pod relying on Karpenter for capacity stays
unschedulable.

## Install

```bash
cd charts/env/prod/critical/karpenter
helm dependency update

helm upgrade --install karpenter . \
  --namespace kube-system \
  -f values.yaml
```

## What this chart does *not* do

* It does not provision IAM roles, discovery tags, or the interruption
  queue — see the prerequisites above.
* It replaces, rather than complements, the EKS managed node group's
  autoscaling: once Karpenter is healthy, scale the existing
  `eks_managed_node_groups.default` min/max down to just enough capacity to
  run cluster-critical add-ons (CoreDNS, the ALB controller, Karpenter
  itself), and let Karpenter own workload capacity via the `NodePool` in
  [`templates/nodepool.yaml`](templates/nodepool.yaml).
