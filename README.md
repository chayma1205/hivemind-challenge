# hivemind-challenge

Infrastructure and GitOps repo for **hivemind-prod**: an Amazon EKS
cluster, provisioned by Terraform and operated by Argo CD, running a
small demo app (`greeter`) behind an ALB with a real domain and TLS.

This repo owns **infrastructure and cluster state** — Terraform for AWS
resources, Helm charts + Argo CD `Application` manifests for everything
that runs in the cluster. The app's own source lives in a separate repo:
[`hivemind-greeter`](https://github.com/chayma1205/hivemind-greeter).

## What's running

- **EKS cluster** (`hivemind-prod`, `us-east-1`) — VPC across 3 AZs, a
  managed node group, and cluster-critical add-ons: Karpenter (node
  autoscaling), the AWS Load Balancer Controller, cert-manager,
  external-dns, the Vertical Pod Autoscaler, and
  [Crossplane](https://crossplane.io/) (AWS resources managed as
  Kubernetes objects — currently the per-hostname ingress TLS certs, via
  a real Composition, not a manual step; see
  [docs/DECISIONS.md](docs/DECISIONS.md) #12).
- **Argo CD**, GitOps-managing everything else via a self-managing
  app-of-apps (`charts/env/prod/argocd-apps.yaml`, generated — see
  [`scripts/generate-argocd-apps.sh`](scripts/generate-argocd-apps.sh)),
  with its Notifications controller alerting on Application
  `OutOfSync`/`Degraded` transitions.
- **Argo CD Image Updater**, watching ECR for new `greeter` releases and
  writing the new tag straight into git.
- **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana) —
  cluster/node/pod metrics and alerting, delivered by email via SNS (no
  static credentials — see
  [that chart's README](charts/env/prod/central-services/kube-prometheus-stack/README.md)).
- **greeter**, a small Go app, deployed from an image built and signed
  (cosign, SBOM, SLSA provenance) by `hivemind-greeter`'s own CI/CD.

Live endpoints (once DNS/TLS are fully synced):

- `https://argocd.hivemind.chaima.online` — Argo CD UI
- `https://greeter.hivemind.chaima.online` — the app
- `https://grafana.hivemind.chaima.online` — dashboards

## Credentials

Admin passwords for Argo CD and Grafana are never committed to this
repo. Two sources, both outside git:

- **Live cluster** (authoritative — read this first):
  ```bash
  # Argo CD
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  # Grafana
  kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
  ```
- **AWS Secrets Manager** (a durable copy, for access without a
  `kubeconfig` — e.g. reviewing this without full cluster access):
  `hivemind-prod/argocd-admin-password` and
  `hivemind-prod/grafana-admin-password`, both in `us-east-1`.
  ```bash
  aws secretsmanager get-secret-value \
    --secret-id hivemind-prod/<argocd|grafana>-admin-password \
    --profile hivemind --region us-east-1 \
    --query SecretString --output text
  ```
  Both usernames are `admin`.

## Repo layout

```
terraform/
  shared/terraform-backend/   S3 state bucket bootstrap (one-time, per account)
  envs/prod/                  VPC, EKS, IAM/Pod Identity, ECR, Route53/ACM
charts/env/prod/
  critical/                   Karpenter, ALB controller, Crossplane, Vertical Pod Autoscaler — cluster-scoped, one per cluster
  central-services/            Argo CD, Argo CD Image Updater, kube-prometheus-stack
  apps/greeter/                 The app's Helm chart (image built elsewhere)
  argocd-apps.yaml              Generated Argo CD Application set — don't hand-edit
scripts/
  generate-argocd-apps.sh      Regenerates argocd-apps.yaml from the chart directories
docs/
  ARCHITECTURE.md              What exists and how it fits together
  DECISIONS.md                 Why — tradeoffs, and decisions later revisited
  RUNBOOK.md                   Day-to-day operational procedures
  DISASTER_RECOVERY.md         What to do when something's actually broken
  ASSESSMENT.md                Honest gap analysis: security, automation, process
```

## Getting started

Full bootstrap-from-scratch steps are in
[docs/DISASTER_RECOVERY.md](docs/DISASTER_RECOVERY.md#scenario-full-cluster-loss)
(they double as the initial setup procedure). Short version:

```bash
# 1. One-time per AWS account: the Terraform state backend
cd terraform/shared/terraform-backend
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply

# 2. The actual infrastructure
cd ../../envs/prod
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
aws eks update-kubeconfig --name hivemind-prod --region us-east-1

# 3. Bootstrap Argo CD (needs a registered git deploy key first —
#    see docs/DISASTER_RECOVERY.md step 4-5 for the exact commands)
cd ../../../charts/env/prod/central-services/argocd
helm dependency update
helm upgrade --install argocd . --namespace argocd --create-namespace -f values.yaml
kubectl apply -n argocd -f ../../argocd-apps.yaml   # one-time; self-manages after this
```

All AWS commands assume the `hivemind` CLI profile and `us-east-1`,
matching the Terraform defaults.

## Related repo

The app's Go source, Dockerfile, and its own CI/CD (build, test, scan,
sign, push) live in
[`hivemind-greeter`](https://github.com/chayma1205/hivemind-greeter) —
split out from this repo so the GitOps/infra side and the application
side can move independently. See
[docs/DECISIONS.md](docs/DECISIONS.md) #11 for why.

## Current known gaps

This is an active build, not a finished production system — see
[docs/ASSESSMENT.md](docs/ASSESSMENT.md) for an honest accounting of
what's missing (no NetworkPolicy, no policy-as-code, no infra tests, no
`LICENSE`/`SECURITY.md`, etc.) before treating this as a template for
anything that actually matters.
