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

**Discovery tags** — Karpenter finds subnets and the node security group by
tag (`karpenter.sh/discovery = hivemind-prod` by default here, see
[`templates/nodeclass.yaml`](templates/nodeclass.yaml)), applied to the
VPC module's private subnets and the EKS node security group in
`terraform/envs/prod/main.tf` (`private_subnet_tags`,
`node_security_group_tags`).

## Install

```bash
cd charts/env/prod/critical/karpenter
helm dependency update

helm upgrade --install karpenter . \
  --namespace kube-system \
  -f values.yaml
```

## NodePool instance selection

[`templates/nodepool.yaml`](templates/nodepool.yaml)'s `requirements`
restrict Karpenter to `amd64`, on-demand, third-generation-or-newer
instances in `nodePool.instanceCategories` (`c`/`m`/`r` by default) —
plus, as of a live incident, excluding `nano`/`micro`/`small`/`medium`
sizes. Confirmed live: a `c7a.medium` (2 vCPU) got picked, and its
max-pods (8, an ENI/IP-allocation limit tied to instance size) was
nearly consumed by baseline DaemonSets alone (VPC CNI, kube-proxy, Pod
Identity agent, EBS CSI node plugin, Secrets Store CSI driver +
provider, kube-prometheus-stack's node-exporter) — one of those
DaemonSet pods ended up permanently `Pending`, pinned by its own
nodeAffinity to that one undersized node with nowhere else it could
schedule. A DaemonSet pod isn't reschedulable onto a *different* node by
Karpenter provisioning more capacity elsewhere, so this needed fixing at
the NodePool level, not by adding nodes.

## What this chart does *not* do

* It does not provision IAM roles, discovery tags, or the interruption
  queue — see the prerequisites above.
* It replaces, rather than complements, the EKS managed node group's
  autoscaling: once Karpenter is healthy, scale the existing
  `eks_managed_node_groups.default` min/max down to just enough capacity to
  run cluster-critical add-ons (CoreDNS, the ALB controller, Karpenter
  itself), and let Karpenter own workload capacity via the `NodePool` in
  [`templates/nodepool.yaml`](templates/nodepool.yaml).
