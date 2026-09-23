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
Route53 — exactly what the ingress-cert Composition below needs. Narrow
or widen it as actual usage grows beyond that.

### `providerConfig.enabled: true` requires the provider to be healthy first

`providers.aws.upbound.io`'s CRDs (including `ProviderConfig` itself)
don't exist until `provider-family-aws` finishes installing — a few
minutes after first sync. Applying the `ProviderConfig` before then fails
with `no matches for kind "ProviderConfig" in version
"aws.upbound.io/v1beta1"`. Same bootstrap-ordering issue the
[`cert-manager`](../../../../../docs/ARCHITECTURE.md) setup solved with
`clusterIssuer.enabled: false` before a real domain existed. On a fresh
cluster, this value starts effectively unusable until `kubectl get
providers` shows `provider-family-aws` `HEALTHY=True` — if it's not yet,
temporarily set `providerConfig.enabled: false`, wait, then flip it back
and re-sync (or let Argo CD self-heal pick it up once the CRDs exist).

## What Crossplane manages: the ingress certs

The ingress TLS certs (argocd/greeter) are provisioned by the
`IngressCertificate` composite resource type defined in
[`templates/xrd-ingresscertificate.yaml`](templates/xrd-ingresscertificate.yaml):
one instance per hostname
([`templates/ingresscertificates.yaml`](templates/ingresscertificates.yaml),
driven by `values.yaml`'s `ingressCertificates.hostnames`), each rendered
by
[`templates/composition-ingresscertificate.yaml`](templates/composition-ingresscertificate.yaml)
into a `Certificate` + Route53 validation `Record` + `CertificateValidation`
(`acm.aws.upbound.io`/`route53.aws.upbound.io` — the same cluster-scoped
CRD group `templates/providerconfig.yaml`'s `ProviderConfig` already
targets, not the newer namespaced `.m.` variant, which needs a
`ClusterProviderConfig` reference instead of the `ProviderConfig` this
chart already has set up).

This is the second attempt at Crossplane-managed certs. The first
(`Certificate`/`Record`/`CertificateValidation` applied directly, no
Composition — see git history) hit a real gap: the Record's validation
CNAME name/value are only known after ACM assigns them when the
Certificate is requested, and a Composition-less setup has no way to
patch one composed resource's observed state into another's desired
state — it needed a value copied in by hand after every first sync.
Confirmed live on a full cluster rebuild that nobody had done that
manual step, so no cert ever got created and the ingresses had no HTTPS.
Moved to Terraform after that (its dependency graph resolves the same
problem in one `apply`), then back here once the actual gap — no
automatic wiring — was fixed with a real Composition.

The fix: a `mode: Pipeline` Composition running the
`function-patch-and-transform` Function, which *can* patch a composed
resource's status into the XR's status (`ToCompositeFieldPath`) and then
back out into a different composed resource's spec
(`FromCompositeFieldPath`) — the two-hop route around "Compositions can't
patch directly between sibling composed resources". The
`validation-record`/`certificate-validation` resources' patches are left
at the function's default (`Required`) `fromFieldPath` policy on purpose:
before the Certificate has been observed, the source field doesn't
exist, so the function skips adding those resources to desired state for
that reconcile instead of creating them with blank fields. Crossplane
reconciles a composite on every observed change to its composed
resources (not just on a timer), so this converges within one or two
reconciles of the Certificate actually existing — no manual step.
`function-auto-ready` is chained after it so the XR's own `Ready`
condition reflects whether all three composed resources are actually
ready, instead of always reading `Ready` regardless of real state.

No `certificate-arn` is wired into either ingress chart's `values.yaml`
— deliberately. The AWS Load Balancer Controller auto-discovers a
matching cert by comparing an Ingress's `spec.tls[].hosts` against ACM
(https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/cert_discovery/),
so creating the right cert is the entire fix.

`docs/DECISIONS.md`/`docs/ASSESSMENT.md` record this back-and-forth as
an architecture decision, not just a bug fix.

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
