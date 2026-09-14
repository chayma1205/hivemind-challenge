# Architecture

## Overview

The greeter app ([`app/greeter.go`](../app/greeter.go)) is a single Go binary
that serves HTTP requests on `:8080`, greeting the caller with its own
hostname and a `HELLO_TAG` value read from the environment. It's packaged as
a container image ([`app/Dockerfile`](../app/Dockerfile)) and runs on Amazon
EKS, built by Terraform ([`terraform/`](../terraform)).

```
                                Internet
                                   │
                        ┌──────────────────┐
                        │  Load Balancer    │  (public subnets)
                        └────────┬─────────┘
                                 │
            ┌────────────────────────────────────────┐
            │              VPC (3 AZs)                │
            │                                          │
            │   public subnets      private subnets    │
            │   (NAT GW, LB)   ───▶ (EKS nodes/pods)    │
            │                                          │
            │        ┌───────────────────────────┐     │
            │        │   EKS cluster              │     │
            │        │  ┌───────────────────────┐ │     │
            │        │  │ greeter Deployment     │ │     │
            │        │  │  (pods across 3 AZs)   │ │     │
            │        │  └───────────────────────┘ │     │
            │        └───────────────────────────┘     │
            └────────────────────────────────────────┘
                                 ▲
                                 │ docker push / image pull
                        ┌──────────────────┐
                        │  ECR repository   │
                        └──────────────────┘
```

## Components

### Application (`app/`)
Stateless Go HTTP server. Reads `HELLO_TAG` and `HOSTNAME` from the
environment at request time, so no rebuild is needed to change the tag —
only a Deployment env var / rollout. Built via a multi-stage Dockerfile
(`golang:1.22-alpine` builder → `distroless/static-debian12` runtime),
producing a small, non-root, shell-less final image.

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
`terraform-aws-modules/ecr/aws` provisions one repository for the greeter
image with:
* `IMMUTABLE` tags — a given tag can never be overwritten, so what's
  deployed is always traceable to a specific build.
* Scan-on-push (basic ECR image scanning for known CVEs).
* A lifecycle policy expiring untagged images after 14 days and keeping the
  most recent 20 tagged images.

### Compute (`terraform/envs/prod/main.tf`)
`terraform-aws-modules/eks/aws` provisions the control plane (`hivemind-prod`)
and one EKS managed node group (`t3.medium`, 2–4 nodes, on-demand) spread
across the private subnets in all 3 AZs. Node AMI is
`AL2023_x86_64_STANDARD`. `enable_cluster_creator_admin_permissions` grants
the applying identity cluster-admin via EKS access entries for initial
bootstrapping.

This node group is labelled `role=system` and tainted
`CriticalAddonsOnly=true:NoSchedule` — it's reserved for the
critical/central-services charts below, not general app workload. See
"What isn't built yet".

### State & locking (`terraform/shared/terraform-backend/`)
A separate bootstrap stack provisions the S3 bucket all other stacks use as
their remote backend (versioned, encrypted, public access blocked,
TLS-only bucket policy). Locking uses the S3 backend's native
`use_lockfile` (Terraform ≥ 1.11) instead of a DynamoDB table — see
[DECISIONS.md](DECISIONS.md).

### Kubernetes workloads (`charts/env/prod/`)
Helm charts, split by role:

* [`critical/`](../charts/env/prod/critical) — cluster-critical add-ons
  (Karpenter, the AWS Load Balancer Controller, metrics-server), each a
  thin wrapper around an upstream chart. Scheduled onto the `role=system`
  node group via matching `nodeSelector`/tolerations and
  `priorityClassName: system-cluster-critical`.
* [`central-services/`](../charts/env/prod/central-services) — Argo CD,
  installed once for the cluster. Same node placement as `critical/`.
* [`apps/`](../charts/env/prod/apps) — actual application workloads (just
  [`greeter`](../charts/env/prod/apps/greeter) today), templated from
  scratch rather than wrapping an upstream chart. Deliberately does *not*
  tolerate the system node group's taint.

## Current live state

`hivemind-prod` is a real running cluster, not just Terraform code, and
has been taken through several rounds of "deploy it, see what actually
breaks, fix it" rather than only validated with `helm template`:

* VPC/ECR/EKS: applied, including the `role=system` taint/label on the
  node group.
* IRSA for Karpenter's controller (+ node IAM role + interruption queue)
  and the ALB controller: applied (`module.karpenter`,
  `module.aws_load_balancer_controller_irsa` in
  `terraform/envs/prod/main.tf`) and wired into their charts' `values.yaml`.
* Karpenter's discovery tags: applied to the VPC's private subnets and the
  EKS node security group — its `NodePool` successfully provisions real
  nodes (verified: `c7a.medium` instances joining and going `Ready`).
* Argo CD: `helm install`ed, healthy, self-managing via
  [`charts/env/prod/argocd-apps.yaml`](../charts/env/prod/argocd-apps.yaml).
  This repo is public specifically so Argo CD can clone it with no stored
  credentials.
* The greeter app: a real image is built, pushed to ECR, and running
  (verified end-to-end with an actual HTTP request through the Service).
* metrics-server: backs the greeter chart's HPA (`autoscaling.enabled:
  true`).

Bugs found and fixed by actually running this (not just reading the specs):
the community `terraform-aws-modules/eks/aws//modules/karpenter` module's
default IAM policy omits `iam:ListInstanceProfiles` (can't be
resource-scoped, so its own scoped statements never cover it); the
NodePool chart had `expireAfter` nested under the wrong API field
(`spec.disruption` instead of `spec.template.spec` — silently accepted on
create, rejected on update); and an `instance-category`-only requirement
let Karpenter select legacy families like `m1.small` that launch but can
never register with the cluster.

## What isn't built yet

* The `HELLO_TAG` URL-parameter change to `app/greeter.go` itself (from the
  challenge README) hasn't been made.
* A CI/CD pipeline (build → scan → push to ECR → update `image.tag` in
  [`charts/env/prod/apps/greeter/argocd-params.env`](../charts/env/prod/apps/greeter/argocd-params.env)
  → regenerate `argocd-apps.yaml` → Argo CD syncs) — today that whole
  sequence is manual.
* Observability beyond metrics-server / EKS-CloudWatch defaults — no log
  aggregation, alerting, or dashboards.

These are called out explicitly (rather than hand-waved) so the current
state of the system is unambiguous; see [RUNBOOK.md](RUNBOOK.md) for what
*can* be operated today.
