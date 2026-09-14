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
  (Karpenter, the AWS Load Balancer Controller), each a thin wrapper
  around an upstream chart. Scheduled onto the `role=system` node group via
  matching `nodeSelector`/tolerations and `priorityClassName:
  system-cluster-critical`.
* [`central-services/`](../charts/env/prod/central-services) — Argo CD,
  installed once for the cluster. Same node placement as `critical/`.
* [`apps/`](../charts/env/prod/apps) — actual application workloads (just
  [`greeter`](../charts/env/prod/apps/greeter) today), templated from
  scratch rather than wrapping an upstream chart. Deliberately does *not*
  tolerate the system node group's taint.

## What isn't built yet

This repo provisions the infrastructure (VPC/ECR/EKS) via Terraform and has
Helm charts for the platform add-ons and the app itself, but several pieces
aren't wired together yet:

* **No general-workload node capacity.** The only node group is reserved
  for critical/central-services (see Compute, above). Karpenter is meant to
  provide general capacity via its `NodePool` once it's running — but it
  isn't yet, because:
* **IRSA roles are missing** for Karpenter's controller and the ALB
  controller (each chart's README documents exactly what's needed). Until
  those exist, neither controller can actually do anything, and the
  greeter app's pods have nowhere to schedule.
* **Nothing is installed yet.** The charts exist and validate
  (`helm template`/`helm lint`), but none have been `helm install`ed onto
  the live cluster.
* The `HELLO_TAG` URL-parameter change to `app/greeter.go` itself (from the
  challenge README) hasn't been made.
* A CI/CD pipeline (build → scan → push to ECR → `helm upgrade`, ideally
  via the now-installed Argo CD rather than a push-based pipeline).
* Observability stack (metrics, logs, alerting) beyond what EKS/CloudWatch
  provide by default — note the app charts also can't autoscale on CPU yet
  since there's no metrics-server.

These are called out explicitly (rather than hand-waved) so the current
state of the system is unambiguous; see [RUNBOOK.md](RUNBOOK.md) for what
*can* be operated today.
