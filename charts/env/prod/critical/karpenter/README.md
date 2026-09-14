# karpenter (env/prod/critical)

Wrapper chart that installs [Karpenter](https://karpenter.sh/) for node
autoscaling in the `hivemind-prod` EKS cluster, plus a default
`NodePool`/`EC2NodeClass` pair so it can actually launch nodes once
installed.

It lives under `charts/env/prod/critical/` (not `central-services/`)
because it's cluster-scoped configuration tied to *this* environment's
cluster name, subnets and node role — unlike Argo CD, which is installed
once per cluster with no per-env values.

## ⚠️ Prerequisites not yet provisioned

This chart alone is not enough to run Karpenter — the following need to
exist first, none of which are in `terraform/envs/prod` yet:

1. **Controller IRSA role** — an IAM role Karpenter's pod assumes via its
   service account, with permissions to create/terminate EC2 instances,
   describe subnets/security groups, etc. Typically provisioned via
   `terraform-aws-modules/eks/aws//modules/karpenter`. Once it exists, set
   `karpenter.serviceAccount.annotations."eks.amazonaws.com/role-arn"` in
   [`values.yaml`](values.yaml).
2. **Node IAM role** — the role EC2 instances Karpenter launches will run
   as (needs `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
   `AmazonEC2ContainerRegistryReadOnly`, and an entry in the cluster's EKS
   access entries / aws-auth). Set `nodePool.nodeRoleName` once it exists.
3. **Discovery tags** — Karpenter finds subnets and the node security group
   by tag (`karpenter.sh/discovery = hivemind-prod` by default
   here). Add this tag to the VPC module's private subnets and to the EKS
   node security group in `terraform/envs/prod`.
4. **Interruption queue** (optional but recommended) — an SQS queue
   receiving EC2 spot-interruption/rebalance events, referenced via
   `karpenter.settings.interruptionQueue`. Only needed if using spot
   capacity.

Each gap is marked `TODO` in [`values.yaml`](values.yaml). Until they're
filled in, `helm install` will succeed (the chart is valid) but the
controller pod will crash-loop on missing permissions / an empty node role.

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
