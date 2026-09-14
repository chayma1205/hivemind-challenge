# Runbook

Operational procedures for the infrastructure in this repo. See
[ARCHITECTURE.md](ARCHITECTURE.md) for what exists and [DECISIONS.md](DECISIONS.md)
for why. Scope: this covers what's actually implemented today (Terraform
infra) — application deployment to the cluster is a manual `kubectl`
procedure until manifests/CI exist (see the gap list in ARCHITECTURE.md).

All commands assume AWS credentials are configured under the `hivemind`
profile (`aws configure --profile hivemind` / SSO login) and region
`us-east-1`, matching the Terraform defaults.

## 1. Bootstrap the Terraform backend (one time, per AWS account)

```bash
cd terraform/shared/terraform-backend
cp terraform.tfvars.example terraform.tfvars   # edit bucket_name if it collides
terraform init
terraform apply
```

Note the `state_bucket_id` output. If it differs from the default
(`hivemind-challenge-tfstate`), update `bucket` in
`terraform/envs/prod/backend.tf` to match before continuing.

This stack's own state stays local (`terraform.tfstate` in that directory —
back it up, don't delete it). See its README for why.

## 2. Provision the prod environment (VPC / ECR / EKS)

```bash
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars   # adjust as needed
terraform init
terraform plan     # review before applying
terraform apply
```

EKS cluster creation typically takes 10-15 minutes.

Useful outputs: `terraform output` shows the ECR repository URL, EKS
cluster name/endpoint, and a ready-to-run `configure_kubectl` command.

## 3. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name hivemind-prod --profile hivemind
kubectl get nodes    # sanity check
```

## 4. Build and push the greeter image

```bash
cd app
ECR_URL=$(terraform -chdir=../terraform/envs/prod output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 --profile hivemind \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}"

TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%s)
docker build -t "$ECR_URL:$TAG" .
docker push "$ECR_URL:$TAG"
```

Tags are immutable (see DECISIONS.md #8) — always push a new tag, never
reuse an existing one.

## 5. Bootstrap Argo CD and hand off to GitOps

Install Argo CD itself once (see
[`charts/env/prod/central-services/argocd/README.md`](../charts/env/prod/central-services/argocd/README.md)):

```bash
cd charts/env/prod/central-services/argocd
helm dependency update
helm upgrade --install argocd . --namespace argocd --create-namespace -f values.yaml
```

Register this repo with Argo CD (it's private — needs a GitHub PAT with
`repo` scope):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd repo add https://github.com/chayma1205/hivemind-challenge.git \
  --username <gh-user> --password <gh-PAT>
```

Then hand every chart in this repo — including Argo CD's own install — to
Argo CD to manage:

```bash
kubectl apply -n argocd -f charts/env/prod/argocd-apps.yaml
```

From this point, changing what's deployed means editing a chart's
`values.yaml` (or, for the greeter image, the `helm.parameters` in
[`argocd-apps.yaml`](../charts/env/prod/argocd-apps.yaml)), committing, and
letting Argo CD's `automated: {prune: true, selfHeal: true}` sync policy
apply it — not running `helm upgrade` by hand.

The `karpenter` and `aws-load-balancer-controller` Applications will sync
but their pods won't come up healthy until the IAM prerequisites in their
respective READMEs are provisioned. The `greeter` Application needs a real
image tag (step 4) — see the `TODO` in `argocd-apps.yaml`.

## 6. Change the `HELLO_TAG`

Edit the `env.HELLO_TAG` parameter in
[`argocd-apps.yaml`](../charts/env/prod/argocd-apps.yaml), commit, and let
Argo CD sync it — `selfHeal: true` means a manual `kubectl set env` gets
reverted on the next sync. For a one-off manual check without going through
git:

```bash
kubectl set env deployment/greeter HELLO_TAG=<new-tag> -n greeter
kubectl rollout status deployment/greeter -n greeter
```

## 7. Scale

Pods: edit `replicaCount` in the greeter chart's `values.yaml` and let Argo
CD sync it (a manual `kubectl scale` gets reverted by `selfHeal`), or for a
one-off manual check:
```bash
kubectl scale deployment/greeter --replicas=<n> -n greeter
```

Nodes (edit and re-apply, or override at apply time):
```bash
cd terraform/envs/prod
terraform apply -var="node_desired_size=<n>" -var="node_max_size=<n>"
```

## 8. Roll back a bad deployment

Revert `image.tag` in `argocd-apps.yaml` to the previous known-good tag and
let Argo CD sync — `selfHeal` will otherwise fight a plain
`kubectl rollout undo` and restore the bad image on its next pass. For an
immediate manual rollback while you prepare that commit:

```bash
kubectl rollout undo deployment/greeter -n greeter
kubectl rollout status deployment/greeter -n greeter
```

## 9. Tear down

Reverse order of creation — EKS/VPC/ECR first, backend bucket last (and
only if nothing else uses it):

```bash
cd terraform/envs/prod
terraform destroy

cd ../../shared/terraform-backend
terraform destroy   # only if no other stack still points at this bucket
```

`force_destroy = false` on both the state bucket and ECR repository means
`destroy` will fail if they aren't empty first — this is deliberate, to
avoid silently losing state history or images. Empty them explicitly
(`aws s3 rm s3://<bucket> --recursive`, delete ECR images) if you actually
intend to remove everything.

## Troubleshooting

**`terraform init` fails to configure the S3 backend** — usually means the
bucket named in `backend.tf` doesn't exist yet or doesn't match the
bootstrap stack's output. Re-run step 1 and confirm `state_bucket_id`.

**State appears locked / "Error acquiring the state lock"** — with
`use_lockfile`, a stale lock is a `.tflock` object left in the state
bucket, normally cleaned up automatically when a run finishes or errors.
If a run was killed uncleanly, use `terraform force-unlock <LOCK_ID>` from
the error message rather than deleting the object by hand.

**`terraform apply` on EKS fails/hangs on node group creation** — check the
private subnets have NAT egress (`enable_nat_gateway`) and that
`node_instance_types` are available in the target AZs; some instance types
aren't offered in every AZ.

**`kubectl` commands fail with "Unauthorized"** — re-run the
`aws eks update-kubeconfig` command from step 3; EKS auth tokens are
short-lived and regenerated per `aws` CLI invocation, and
`enable_cluster_creator_admin_permissions` only grants access to the
identity that ran `terraform apply`.
