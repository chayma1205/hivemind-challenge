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

### IAM role scope

`aws_iam_role.crossplane_aws_provider` in `domain.tf` is scoped to ACM +
Route53. Currently unused by anything live (see below for why) — kept as
a ready-to-use starting scope rather than reverted to a placeholder,
since it's already narrow (one hosted zone, no wildcard resources) and
this is the obvious place to manage a specific per-domain cert or other
AWS resource on demand. Narrow or widen it as actual usage emerges.

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

## What Crossplane doesn't manage (anymore): the ingress certs

The ingress TLS certs (argocd/greeter) were briefly Crossplane-managed —
a `Certificate` + `Record` + `CertificateValidation` trio
(`acm.aws.upbound.io`/`route53.aws.upbound.io`). Moved back to Terraform
(`terraform/envs/prod/domain.tf`'s `aws_acm_certificate.ingress`, one per
hostname): the Record's validation CNAME name/value are only known after
ACM assigns them when the Certificate is requested, and this repo had no
Crossplane Composition to wire that automatically — it needed a value
copied by hand into `values.yaml` after every first sync. Confirmed live
on a full cluster rebuild: nobody had done that manual step, so no cert
ever got created and the ingresses had no HTTPS at all. Terraform's
dependency graph resolves the same problem in one `apply`, no manual step
— see `domain.tf`'s comment on `aws_acm_certificate.ingress` for the
full reasoning, and `docs/DECISIONS.md`/`docs/ASSESSMENT.md` for this as
a recorded architecture decision, not just a bug fix.

`provider-aws-acm`/`provider-aws-route53` stay installed (see
`values.yaml`) — harmless idle, and the natural place to manage a
specific per-domain cert or other AWS resource through Crossplane again
later, on purpose, ideally with a real Composition this time rather than
a manual-value gate.

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
