# Architecture

## Overview

This repo provisions and operates **hivemind-prod**, an Amazon EKS
cluster running a small demo app (`greeter`) behind a real domain with
TLS. It owns infrastructure (Terraform) and cluster state (Helm charts +
Argo CD). The app's own source, Dockerfile, and CI/CD live in a separate
repo — [`hivemind-greeter`](https://github.com/chayma1205/hivemind-greeter)
— split out from this one so the two can move independently (see
[DECISIONS.md](DECISIONS.md) #11).

```
                                Internet
                                   │
                        ┌──────────────────┐
                        │   ALB (HTTPS)     │  argocd.hivemind.chaima.online
                        │                   │  greeter.hivemind.chaima.online
                        └────────┬─────────┘
                                 │
            ┌────────────────────────────────────────┐
            │              VPC (3 AZs)                │
            │                                          │
            │   public subnets      private subnets    │
            │   (NAT GW, ALB)  ───▶ (EKS nodes/pods)    │
            │                                          │
            │        ┌───────────────────────────┐     │
            │        │   EKS cluster              │     │
            │        │  ┌───────────────────────┐ │     │
            │        │  │ greeter Deployment     │ │     │
            │        │  │  (pods, Karpenter-     │ │     │
            │        │  │   scaled nodes)        │ │     │
            │        │  └───────────────────────┘ │     │
            │        │  Argo CD, Karpenter, ALB   │     │
            │        │  controller, Crossplane,   │     │
            │        │  cert-manager/external-dns │     │
            │        │  (EKS addons)              │     │
            │        └───────────────────────────┘     │
            └────────────────────────────────────────┘
                                 ▲
                                 │ image pull
                        ┌──────────────────┐
                        │  ECR (greeter +   │
                        │  cosign sigs)     │
                        └──────────────────┘
                                 ▲
                                 │ build, scan, sign, push
                          hivemind-greeter repo (separate)
```

## Components

### Application

Stateless Go HTTP server (source in `hivemind-greeter`). Reads
`HELLO_TAG` and `HOSTNAME` from the environment at request time, so no
rebuild is needed to change the tag — only a Deployment env var/rollout.
Built via a multi-stage Dockerfile (`golang:1.25-alpine` builder →
`distroless/static-debian12` runtime): small, non-root, shell-less final
image.

### Networking (`terraform/envs/prod/main.tf`)

`terraform-aws-modules/vpc/aws` provisions a VPC spanning 3 availability
zones with:
* Public subnets — internet-facing load balancers and NAT gateways.
* Private subnets — EKS nodes and pods (no direct inbound internet access).
* One NAT gateway per AZ by default (`single_nat_gateway = false`) so a
  single AZ's NAT failure doesn't take down egress cluster-wide.

Subnets carry the `kubernetes.io/role/elb` / `kubernetes.io/role/internal-elb`
and `kubernetes.io/cluster/<name>` tags EKS and the AWS Load Balancer
Controller use for auto-discovery.

### Container registry (`terraform/envs/prod/main.tf`)

Two ECR repositories:
* `hivemind-greeter` — the app image. `IMMUTABLE` tags (a given tag can
  never be overwritten, so what's deployed is always traceable to a
  specific build), scan-on-push, a lifecycle policy expiring untagged
  images after 14 days and keeping the most recent 20 tagged.
* `hivemind-greeter-signatures` — cosign signatures, SBOM, and SLSA
  provenance attestations for those images, pushed by `hivemind-greeter`'s
  CI. `MUTABLE` tags, deliberately: cosign rewrites its `.sig`/`.att` tags
  in place, which would conflict with the app repo's IMMUTABLE policy.

### Compute (`terraform/envs/prod/main.tf`)

`terraform-aws-modules/eks/aws` provisions the control plane
(`hivemind-prod`, Kubernetes 1.36) and one EKS managed node group
(`t3.large`, 2–4 nodes, on-demand) spread across the private subnets in
all 3 AZs. Node AMI is `AL2023_x86_64_STANDARD`.
`enable_cluster_creator_admin_permissions` grants the applying identity
cluster-admin via EKS access entries for initial bootstrapping. The
public API endpoint is restricted to a specific operator CIDR (see
DECISIONS.md #6) rather than open to the internet.

This node group is labelled `role=system` and tainted
`CriticalAddonsOnly=true:NoSchedule` — reserved for the critical/
central-services charts, not general app workload. General workload
capacity comes from Karpenter's `NodePool` instead, which provisions real
nodes on demand (verified: `c7a.medium` instances joining and going
`Ready`).

**EKS addons** (`module.eks.cluster_addons`), all AWS-managed rather than
self-installed Helm charts: `vpc-cni`, `coredns`, `kube-proxy`,
`eks-pod-identity-agent`, `external-dns`, `metrics-server`,
`cert-manager`. Pinned to specific versions rather than tracking "latest"
implicitly. `external-dns` and `cert-manager` authenticate to AWS via
**EKS Pod Identity** (not IRSA — these addons expose no serviceAccount-
annotation surface to attach an IRSA role to), wired in
`terraform/envs/prod/domain.tf`.

`cert-manager` is currently running but idle — nothing requests a
`ClusterIssuer`/`Certificate` from it. Ingress TLS goes through ACM
instead (see below), which is the native way the AWS Load Balancer
Controller terminates HTTPS.

### Domain and TLS (`terraform/envs/prod/domain.tf`,
`charts/env/prod/critical/crossplane`)

The public hosted zone (`hivemind.chaima.online`) is **out-of-band** —
created manually, not Terraform-managed (`domain.tf` only does a
`data "aws_route53_zone"` lookup; see DECISIONS.md and
[DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) for what that means if it's
ever lost). `external-dns` watches Ingress objects and writes matching
Route53 A/AAAA/TXT records automatically.

The ALB-fronted ingress TLS certs (one per hostname — `argocd`,
`greeter` — not a shared wildcard) are **Crossplane**-managed: an
`IngressCertificate` composite resource per hostname
(`charts/env/prod/critical/crossplane/templates/ingresscertificates.yaml`),
rendered by a `function-patch-and-transform` Composition into an ACM
`Certificate` + Route53 validation `Record` + `CertificateValidation`.
This is the second attempt — a first, Composition-less pass needed the
validation record's value copied in by hand and got reverted to
Terraform; moved back once a real Composition closed that gap. See
DECISIONS.md and the crossplane chart's README for the full history and
how the automatic wiring works.

### State & locking (`terraform/shared/terraform-backend/`)

A separate bootstrap stack provisions the S3 bucket all other stacks use
as their remote backend (versioned, encrypted, public access blocked,
TLS-only bucket policy). Locking uses the S3 backend's native
`use_lockfile` (Terraform ≥ 1.11) instead of a DynamoDB table — see
[DECISIONS.md](DECISIONS.md).

### Kubernetes workloads (`charts/env/prod/`)

Helm charts, split by role:

* [`critical/`](../charts/env/prod/critical) — cluster-critical add-ons
  not covered by an EKS addon: Karpenter, the AWS Load Balancer
  Controller, and Crossplane. Each a thin wrapper around an upstream
  chart, scheduled onto the `role=system` node group via matching
  `nodeSelector`/tolerations.
* [`central-services/`](../charts/env/prod/central-services) — Argo CD
  and Argo CD Image Updater, installed once for the cluster. Same node
  placement as `critical/`.
* [`apps/`](../charts/env/prod/apps) — actual application workloads (just
  [`greeter`](../charts/env/prod/apps/greeter) today), templated from
  scratch rather than wrapping an upstream chart. Deliberately does *not*
  tolerate the system node group's taint.

`charts/env/prod/argocd-apps.yaml` is **generated**
(`scripts/generate-argocd-apps.sh`) from those chart directories, not
hand-maintained — includes a self-managing `root` Application so every
regeneration is picked up and applied automatically after the one-time
bootstrap `kubectl apply`.

## CI/CD

Split across two repos (see DECISIONS.md #11 for why):

* **This repo**: [`ci.yml`](../.github/workflows/ci.yml) lints the
  greeter Helm chart and checks `argocd-apps.yaml` is up to date with the
  chart directories on every PR/push touching `charts/**`. No app build,
  no AWS credentials — this repo is GitOps-only.
* **`hivemind-greeter`**: owns the Go build/test, Docker build, Trivy
  scan, cosign signing (keyless, OIDC identity, Rekor transparency log),
  SBOM generation, and SLSA v1 provenance attestation. Pushes to ECR via
  GitHub OIDC (`module.github_actions_ecr_push_irsa` in
  `terraform/envs/prod/github.tf` — short-lived per-run credentials, no
  static AWS key). Three triggers: `main` push → commit-SHA tag,
  `releases/**` branch → staging tag (no staging cluster exists yet to
  deploy it to), and a published GitHub Release (`vX.Y.Z`) → the tag that
  actually reaches prod.
* **Prod hand-off**: Argo CD Image Updater (not a git commit-back step in
  either repo's CI) watches ECR for tags matching `^v[0-9]+\.[0-9]+\.[0-9]+$`
  and writes the new `image.tag` directly into
  `charts/env/prod/apps/greeter/values.yaml` via its own git write-back —
  a separate, write-scoped SSH deploy key from the one Argo CD's
  repo-server uses to clone/sync (this repo is private; see
  DECISIONS.md #10).

## Bugs found only by running the thing

Deliberately kept here rather than only in
[ASSESSMENT.md](ASSESSMENT.md) — this is the running list of "looked
correct on paper, broke live" issues, useful context for anyone extending
this stack:

* The community `terraform-aws-modules/eks/aws//modules/karpenter`
  module's default IAM policy omits `iam:ListInstanceProfiles` (can't be
  resource-scoped, so its own scoped statements never cover it).
* Karpenter's `NodePool` chart had `expireAfter` nested under the wrong
  API field (`spec.disruption` instead of `spec.template.spec`) —
  silently accepted on create, rejected on update.
* An `instance-category`-only requirement let Karpenter select legacy
  families like `m1.small` that launch but can never register with the
  cluster.
* GitHub's OIDC `sub` claim for repos created after 2026-07-15 uses an
  "immutable subject" format — `repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:...`
  — not the older `repo:owner/repo:ref:...` shown in most tutorials. The
  AWS IAM trust condition using the old format never matched, and
  `sts:AssumeRoleWithWebIdentity` failed with no indication why until
  traced back to this.
* `external-dns`'s EKS Pod Identity association was wired to
  `kube-system` — the addon actually deploys into its own `external-dns`
  namespace. The association silently never matched, so the pod fell
  back to the node group's IAM role (zero Route53 permissions) instead of
  erroring, and no DNS records were ever created.
* The node security group's default rules (from the EKS module) cover the
  control plane's usual webhook ports but not metrics-server's own
  aggregated-API port (10251) — the `v1beta1.metrics.k8s.io` APIService
  couldn't register at all, which cascaded into every HPA in the cluster
  reporting `<unknown>` targets and, from there, into Argo CD marking
  unrelated-looking Applications `Degraded`.
* Crossplane's own custom-resource templates (`DeploymentRuntimeConfig`,
  etc.) raced Crossplane's own bootstrap: Argo CD validates every
  resource's CRD is discoverable *before* wave-sequencing starts, so
  applying a CR whose CRD is registered by Crossplane core at pod
  startup — in the same sync as that pod being created — failed the
  entire sync batch, every retry. `sync-wave` annotations alone didn't
  fix it; needed `SkipDryRunOnMissingResource=true`.

See [ASSESSMENT.md](ASSESSMENT.md) for what this pattern says about the
project's verification layer versus its decision-making.

## What isn't built yet

* The `HELLO_TAG` URL-parameter change (from the original challenge
  brief) hasn't been made — still env-var only, in `hivemind-greeter`.
* No staging environment — `hivemind-greeter`'s `cd-staging.yml` builds
  and pushes staging-tagged images with nowhere to deploy them.
* Observability beyond metrics-server / EKS-CloudWatch defaults — no log
  aggregation, alerting, or dashboards.
* No NetworkPolicy, no Pod-level `securityContext` hardening, no
  policy-as-code on the Terraform, no infra/integration tests — see
  [ASSESSMENT.md](ASSESSMENT.md) for the full gap list.

These are called out explicitly (rather than hand-waved) so the current
state of the system is unambiguous; see [RUNBOOK.md](RUNBOOK.md) for what
*can* be operated today.
