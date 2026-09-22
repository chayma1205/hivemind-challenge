# Runbook

Operational procedures for the infrastructure in this repo. See
[ARCHITECTURE.md](ARCHITECTURE.md) for what exists and
[DECISIONS.md](DECISIONS.md) for why. For "something's actually broken,"
see [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) instead — this doc
covers routine operation, that one covers recovery.

The app's own source lives in a separate repo —
[`hivemind-greeter`](https://github.com/chayma1205/hivemind-greeter) —
this repo only covers infrastructure and GitOps.

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
(`hivemind-challenge-greeter-tfstate`), update `bucket` in
`terraform/envs/prod/backend.tf` to match before continuing.

This stack's own state stays local (`terraform.tfstate` in that directory
— back it up, don't delete it). See its README for why.

## 2. Provision the prod environment (VPC / ECR / EKS / domain)

```bash
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars   # adjust as needed
terraform init
terraform plan     # review before applying
terraform apply
```

EKS cluster creation typically takes 10-15 minutes. Requires the
`hivemind.chaima.online` Route53 hosted zone to already exist (it's
out-of-band, not Terraform-managed — see DISASTER_RECOVERY.md if it
doesn't).

Useful outputs: `terraform output` shows the ECR repository URL, EKS
cluster name/endpoint, and a ready-to-run `configure_kubectl` command.

## 3. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name hivemind-prod --profile hivemind
kubectl get nodes    # sanity check
```

## 4. Build and push the greeter image

Normally automatic, from the **`hivemind-greeter`** repo, not this one:
merging to `main` there runs `ci.yml` (build/test/scan) then `cd.yml`
(build, scan, sign, push to ECR via GitHub OIDC). Publishing a GitHub
Release (`vX.Y.Z`) there is what actually reaches prod — Argo CD Image
Updater watches ECR for that tag shape and writes it into this repo's
`charts/env/prod/apps/greeter/values.yaml` on its own; nothing further to
do here.

For a manual build/push (debugging, or bootstrapping before CI has ever
run — e.g. right after `hivemind-greeter` was first split out and its
ECR repo was empty):

```bash
git clone https://github.com/chayma1205/hivemind-greeter /tmp/hivemind-greeter
cd /tmp/hivemind-greeter/app

ECR_URL=$(terraform -chdir=<this-repo>/terraform/envs/prod output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 --profile hivemind \
  | buildah login --username AWS --password-stdin "${ECR_URL%%/*}"
  # (or `docker login` if docker is available — buildah is a drop-in
  # substitute used in this session's environment, which had no docker)

TAG=$(git rev-parse --short HEAD)
buildah bud -t "$ECR_URL:$TAG" -f Dockerfile .
buildah push "$ECR_URL:$TAG"
```

Tags are immutable (see DECISIONS.md #8) — always push a new tag, never
reuse an existing one. If this tag doesn't match what
`charts/env/prod/apps/greeter/values.yaml`'s `image.tag` expects, update
it and let Argo CD sync (or `kubectl set env`/`kubectl rollout restart`
for an immediate one-off check).

## 5. Bootstrap Argo CD and hand off to GitOps

This repo is **private** (see [DECISIONS.md](DECISIONS.md) #10), so Argo
CD needs a registered git credential before it can clone anything — two SSH deploy keys, generated once and never stored anywhere
but GitHub + the cluster:

```bash
ssh-keygen -t ed25519 -f /tmp/argocd_deploy_key -N "" -C "argocd-hivemind-prod-readonly"
ssh-keygen -t ed25519 -f /tmp/image_updater_write_key -N "" -C "argocd-image-updater-hivemind-prod-write"

gh repo deploy-key add /tmp/argocd_deploy_key.pub --repo chayma1205/hivemind-challenge \
  --title "argocd-hivemind-prod-readonly"                      # read-only
gh repo deploy-key add /tmp/image_updater_write_key.pub --repo chayma1205/hivemind-challenge \
  --title "argocd-image-updater-hivemind-prod-write" -w        # write, separate key

kubectl create namespace argocd

kubectl -n argocd create secret generic hivemind-challenge-repo-creds \
  --from-literal=type=git \
  --from-literal=url=git@github.com:chayma1205/hivemind-challenge.git \
  --from-file=sshPrivateKey=/tmp/argocd_deploy_key
kubectl -n argocd label secret hivemind-challenge-repo-creds \
  argocd.argoproj.io/secret-type=repository

kubectl -n argocd create secret generic argocd-image-updater-git-creds \
  --from-file=sshPrivateKey=/tmp/image_updater_write_key

rm /tmp/argocd_deploy_key /tmp/argocd_deploy_key.pub /tmp/image_updater_write_key /tmp/image_updater_write_key.pub
```

This is a deliberate manual step, not an oversight — see
DECISIONS.md #10 on why an agent or pipeline writing credentials into a
cluster isn't something to automate away.

Install Argo CD itself:

```bash
cd charts/env/prod/central-services/argocd
helm dependency update
helm upgrade --install argocd . --namespace argocd --create-namespace -f values.yaml
```

Hand every chart in this repo — including Argo CD's own install — to
Argo CD to manage:

```bash
kubectl apply -n argocd -f charts/env/prod/argocd-apps.yaml
```

This is a one-time step. That file includes a `root` Application that
watches itself, so every future regeneration — via
`scripts/generate-argocd-apps.sh` — is picked up and applied
automatically. `kubectl apply` only needs running again if the `root`
Application itself is ever deleted.

From this point, changing what's deployed means editing a chart's
`values.yaml`, committing, and letting Argo CD's
`automated: {prune: true, selfHeal: true}` sync policy apply it — not
running `helm upgrade` by hand. The exception:
`charts/env/prod/apps/greeter/values.yaml`'s `image.tag` is owned by
Argo CD Image Updater once it's running — a hand-edit there gets
overwritten on its next cycle; bump the version by cutting a Release in
`hivemind-greeter` instead.

## 6. Access Argo CD

No ingress hostname works until DNS + the ACM cert are both fully synced
(see ARCHITECTURE.md's domain/TLS section). Until then, or for quick
local access regardless:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Then browse **`http://localhost:8080`** — not `https://`: the server
runs with `server.insecure: true` (TLS is meant to terminate at the ALB),
so it only speaks plain HTTP on that port even though the Service also
exposes a "443" port name.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
Username `admin`. Rotate after first login
(`argocd account update-password`).

## 7. Change the `HELLO_TAG`

Edit `env.HELLO_TAG` in
[`charts/env/prod/apps/greeter/argocd-params.env`](../charts/env/prod/apps/greeter/argocd-params.env),
regenerate (`./scripts/generate-argocd-apps.sh`), commit, and let Argo CD
sync it — `selfHeal: true` means a manual `kubectl set env` gets reverted
on the next sync. For a one-off manual check without going through git:

```bash
kubectl set env deployment/greeter HELLO_TAG=<new-tag> -n greeter
kubectl rollout status deployment/greeter -n greeter
```

## 8. Scale

Pods: edit `replicaCount` in the greeter chart's `values.yaml` and let
Argo CD sync it (a manual `kubectl scale` gets reverted by `selfHeal`),
or for a one-off manual check:
```bash
kubectl scale deployment/greeter --replicas=<n> -n greeter
```

Nodes (edit and re-apply, or override at apply time):
```bash
cd terraform/envs/prod
terraform apply -var="node_desired_size=<n>" -var="node_max_size=<n>"
```
General app workload also autoscales via Karpenter independently of the
managed node group above.

## 9. Roll back a bad deployment

Revert the offending commit and let Argo CD sync — `selfHeal` will
otherwise fight a plain `kubectl rollout undo` and restore the bad state
on its next pass:

```bash
git revert <bad-commit>
git push origin main
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

For greeter specifically, a bad *image* means fixing it upstream in
`hivemind-greeter` and cutting a new Release — Image Updater owns
`image.tag` and will overwrite a hand-revert of just that field. For an
immediate manual rollback while you prepare the real fix:

```bash
kubectl rollout undo deployment/greeter -n greeter
kubectl rollout status deployment/greeter -n greeter
```

## 10. Tear down

Reverse order of creation — EKS/VPC/ECR first, backend bucket last (and
only if nothing else uses it):

```bash
cd terraform/envs/prod
terraform destroy

cd ../../shared/terraform-backend
terraform destroy   # only if no other stack still points at this bucket
```

`force_destroy = false` on both ECR repositories and the state bucket
means `destroy` will fail if they aren't empty first — deliberate, to
avoid silently losing image/state history. Empty them explicitly
(`aws s3 rm s3://<bucket> --recursive`, delete ECR images) if you
actually intend to remove everything. The Route53 hosted zone is
untouched either way — it's out-of-band, not part of this Terraform
state.

## Troubleshooting

**`terraform init` fails to configure the S3 backend** — usually means
the bucket named in `backend.tf` doesn't exist yet or doesn't match the
bootstrap stack's output. Re-run step 1 and confirm `state_bucket_id`.

**State appears locked / "Error acquiring the state lock"** — with
`use_lockfile`, a stale lock is a `.tflock` object left in the state
bucket, normally cleaned up automatically when a run finishes or errors.
If a run was killed uncleanly, use `terraform force-unlock <LOCK_ID>` from
the error message rather than deleting the object by hand.

**`terraform apply` on EKS fails/hangs on node group creation** — check
the private subnets have NAT egress (`enable_nat_gateway`) and that
`node_instance_types` are available in the target AZs; some instance
types aren't offered in every AZ.

**`kubectl` commands fail with "Unauthorized"** — re-run the
`aws eks update-kubeconfig` command from step 3; EKS auth tokens are
short-lived and regenerated per `aws` CLI invocation, and
`enable_cluster_creator_admin_permissions` only grants access to the
identity that ran `terraform apply`. Also check
`cluster_endpoint_public_access_cidrs` in `terraform/envs/prod/variables.tf`
still matches your current egress IP — it's a static allowlist, not
auto-updating.

**A Pod Identity-authenticated addon (external-dns, cert-manager,
Crossplane's AWS provider) is getting `AccessDenied`** — check its pod is
actually running in the namespace the `aws_eks_pod_identity_association`
targets in `terraform/envs/prod/domain.tf`. A mismatch fails silently:
the pod falls back to the node group's IAM role instead of erroring at
startup (this exact bug hit `external-dns` — see ARCHITECTURE.md).

**HPA shows `<unknown>` targets / `kubectl top nodes` fails** — check
`kubectl get apiservice v1beta1.metrics.k8s.io -o yaml` for a discovery
error. If the control plane can't reach the metrics-server pod, check the
node security group has the `ingress_cluster_metrics_server` rule
(`terraform/envs/prod/main.tf`) — this exact gap has hit the cluster
before (see ARCHITECTURE.md).

**A node has `Ready: Unknown` and pods stuck `Terminating` on it** — its
kubelet has stopped posting status; this can happen with a
Karpenter-provisioned node even while the underlying EC2 instance is
still `running`. Don't delete the Kubernetes `Node` object directly —
remove the Karpenter `NodeClaim` instead, so Karpenter properly
terminates the instance and reschedules the stuck pods:
```bash
kubectl get nodeclaims   # find the one whose NODE matches the bad node
kubectl delete nodeclaim <name>
```
