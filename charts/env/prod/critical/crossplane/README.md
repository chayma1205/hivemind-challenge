# crossplane (env/prod/critical)

Wrapper chart that installs [Crossplane](https://crossplane.io/) — a
Kubernetes-native control plane for provisioning cloud infrastructure via
CRDs — into the `hivemind-prod` EKS cluster, plus the AWS family
meta-provider (`provider-family-aws`) and the plumbing to authenticate it
to AWS without static credentials.

Lives under `charts/env/prod/critical/` for the same reason as
[`../karpenter`](../karpenter) and
[`../aws-load-balancer-controller`](../aws-load-balancer-controller):
cluster-scoped, one per cluster, pinned to the system node group.

## How the AWS provider gets credentials

Crossplane core itself needs no AWS access — only the `provider-family-aws`
pod it installs does. That pod authenticates via **EKS Pod Identity**, not
IRSA:

1. [`values.yaml`](values.yaml)'s `crossplane.provider.packages` installs
   `provider-family-aws` at sync time (via the chart's own
   `core init --provider` init container — no separate `kubectl apply`
   step).
2. [`templates/deploymentruntimeconfig.yaml`](templates/deploymentruntimeconfig.yaml)
   is a `DeploymentRuntimeConfig` named `default` — the CRD's own default
   for `Provider.spec.runtimeConfigRef.name`, so the provider installed
   above picks it up automatically. It pins the provider pod's
   ServiceAccount to a fixed name (`provider-aws`, instead of the package
   manager's hash-suffixed default) and to the system node group.
3. `terraform/envs/prod/domain.tf`'s `aws_eks_pod_identity_association.crossplane_aws_provider`
   binds that exact `(namespace: crossplane-system, service_account:
   provider-aws)` pair to an IAM role
   (`aws_iam_role.crossplane_aws_provider`).
4. [`templates/providerconfig.yaml`](templates/providerconfig.yaml) (once
   enabled, see below) creates a `ProviderConfig` with
   `spec.credentials.source: PodIdentity`, which reads those Pod
   Identity-injected credentials — no `Secret` needed.

### ⚠️ IAM role is a minimal placeholder

`aws_iam_role.crossplane_aws_provider` in `domain.tf` is scoped to just
`sts:GetCallerIdentity` for now (proves the Pod Identity credential chain
works end-to-end without granting any real resource access). Attach real
permissions — AWS managed policies or hand-written ones — once you decide
which AWS resources Crossplane should actually manage; narrow the role
`Provider` and its Kubernetes claims will need.

### ⚠️ `providerConfig.enabled: false` until the provider is healthy

`providers.aws.upbound.io`'s CRDs (including `ProviderConfig` itself)
don't exist until `provider-family-aws` finishes installing — a few
minutes after first sync. Applying the `ProviderConfig` before then fails
with `no matches for kind "ProviderConfig" in version
"aws.upbound.io/v1beta1"`. Same bootstrap-ordering issue the
[`cert-manager`](../../../../../docs/ARCHITECTURE.md) setup solved with
`clusterIssuer.enabled: false` before a real domain existed. Once
`kubectl get providers` shows `provider-family-aws` `HEALTHY=True`, flip
`providerConfig.enabled: true` and re-sync (or let Argo CD self-heal pick
it up next pass).

## Install

```bash
cd charts/env/prod/critical/crossplane
helm dependency update

helm upgrade --install crossplane . \
  --namespace crossplane-system --create-namespace \
  -f values.yaml
```

## Notes

* `replicas: 2` on both the Crossplane and RBAC Manager pods for HA,
  unlike the chart's own default of 1.
* Adding a specific AWS service provider later (e.g. `provider-aws-s3`)
  is just another entry in `crossplane.provider.packages` — it'll pick up
  the same `default` `DeploymentRuntimeConfig` and `ProviderConfig`
  (shared identity across the family) unless you give it its own.
