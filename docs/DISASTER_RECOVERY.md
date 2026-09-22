# Disaster recovery

Concrete recovery procedures for this stack, written against what's
actually here (not a generic template) — real bucket names, real repo
paths, real commands. Companion to [RUNBOOK.md](RUNBOOK.md) (day-to-day
operations) and [ARCHITECTURE.md](ARCHITECTURE.md) (what exists and why).

## What's actually backed up, and what isn't

Understanding this is the whole point of a DR doc — most of this stack
recovers itself from git + Terraform state; a few things don't and need
their own answer.

| What | Where it lives | Recovers how |
|---|---|---|
| Terraform state | `s3://hivemind-challenge-greeter-tfstate/envs/prod/terraform.tfstate` — versioned, S3-native-locked | Automatic (S3 versioning) unless the bucket itself is deleted — see [Scenario: state bucket lost](#scenario-terraform-state-bucket-lost) |
| Infra definitions (VPC, EKS, IAM, ECR, Route53 records/IAM, ACM) | `terraform/envs/prod/*.tf` in this repo (git) | `terraform apply` from a fresh clone |
| GitOps definitions (what Argo CD runs) | `charts/env/prod/**` + `argocd-apps.yaml` in this repo (git) | Automatic once Argo CD is bootstrapped (self-managing root Application, see below) |
| App source + build pipeline | Separate repo: `github.com/chayma1205/hivemind-greeter` | Independent of this repo; re-clone + re-run CI |
| Container images | ECR (`hivemind-greeter`, `hivemind-greeter-signatures`) | **Not backed up** — lost if the repos are deleted. Rebuildable from `hivemind-greeter` git history, but re-signing needs a fresh CI run (new signatures, same image bytes) |
| Route53 public hosted zone (`hivemind.chaima.online`) | Created **out-of-band**, not Terraform-managed — `domain.tf` only does `data "aws_route53_zone"` lookup | **Not recoverable by this repo.** If the zone is deleted, someone has to recreate it and redo NS delegation from the parent `chaima.online` zone/registrar by hand. This is the single biggest single-point-of-failure in the whole stack. |
| DNS records inside that zone | Managed by external-dns from live Ingress state | Automatic — external-dns reconciles every ~60s once it and the ingresses exist again |
| ACM wildcard cert | AWS ACM (currently Terraform-managed pending migration to Crossplane — see `docs/DECISIONS.md`) | Recreatable, but DNS-validation needs the hosted zone above to exist first |
| Git credentials (2 SSH deploy keys: repo-server read-only, Image Updater write) | **Only as GitHub deploy keys + the two K8s Secrets in the `argocd` namespace.** Not stored anywhere else — not in git (correctly), not in a password manager as far as this repo knows. | **Not recoverable — must be regenerated.** See [Scenario: cluster lost](#scenario-full-cluster-loss). |
| Kubernetes workload state (Deployments, etc.) | Rendered from Helm charts in git, applied by Argo CD | Automatic |
| Application data | None — greeter is stateless; Crossplane manages external AWS resources, not in-cluster data | N/A |

**The practical takeaway:** infra and GitOps config are fully
git-recoverable. The two things that are genuinely gone if lost — no
backup exists — are the **Route53 hosted zone** (needs a human to
recreate + re-delegate) and the **git SSH deploy keys** (regenerate +
re-register, ~5 minutes, see below). Everything else is a `terraform
apply` + waiting for GitOps to catch up.

## Prerequisites for any recovery

- AWS CLI configured with the `hivemind` profile, sufficient IAM
  permissions (the operator who ran the original `terraform apply` has
  this; a fresh operator needs equivalent access).
- `kubectl`, `helm`, `terraform` (≥1.11 — required for S3 native state
  locking), `gh` CLI authenticated against `chayma1205`.
- This repo cloned, and `hivemind-greeter` cloned if an image rebuild is
  needed.

## Scenario: full cluster loss

EKS cluster deleted, corrupted, or the account/region needs a full
rebuild from scratch. Terraform state and git are both intact.

1. **Confirm the Route53 zone still exists** — this is the one thing
   Terraform won't recreate for you:
   ```bash
   aws route53 list-hosted-zones --profile hivemind \
     --query "HostedZones[?Name=='hivemind.chaima.online.']"
   ```
   If it's gone, stop here and see
   [Scenario: Route53 zone lost](#scenario-route53-hosted-zone-lost)
   first — everything below assumes it exists.

2. **Rebuild the infrastructure:**
   ```bash
   cd terraform/envs/prod
   terraform init
   terraform plan -out=tfplan   # review — should be a clean create, no
                                 # surprise destroys of unrelated resources
   terraform apply tfplan
   ```
   This recreates the VPC (if also lost), EKS cluster, node group, all
   IAM roles/Pod Identity associations, ECR repos, and (currently) the
   ACM cert. Expect ~15-20 minutes for the EKS control plane alone.

3. **Configure kubectl:**
   ```bash
   aws eks update-kubeconfig --name hivemind-prod --region us-east-1 --profile hivemind
   ```

4. **Regenerate and register the two git deploy keys** (these are gone —
   see the table above):
   ```bash
   ssh-keygen -t ed25519 -f /tmp/argocd_deploy_key -N "" -C "argocd-hivemind-prod-readonly"
   ssh-keygen -t ed25519 -f /tmp/image_updater_write_key -N "" -C "argocd-image-updater-hivemind-prod-write"

   gh repo deploy-key add /tmp/argocd_deploy_key.pub --repo chayma1205/hivemind-challenge \
     --title "argocd-hivemind-prod-readonly"
   gh repo deploy-key add /tmp/image_updater_write_key.pub --repo chayma1205/hivemind-challenge \
     --title "argocd-image-updater-hivemind-prod-write" -w
   ```

5. **Bootstrap Argo CD:**
   ```bash
   kubectl create namespace argocd

   kubectl -n argocd create secret generic hivemind-challenge-repo-creds \
     --from-literal=type=git \
     --from-literal=url=git@github.com:chayma1205/hivemind-challenge.git \
     --from-file=sshPrivateKey=/tmp/argocd_deploy_key
   kubectl -n argocd label secret hivemind-challenge-repo-creds \
     argocd.argoproj.io/secret-type=repository

   kubectl -n argocd create secret generic argocd-image-updater-git-creds \
     --from-file=sshPrivateKey=/tmp/image_updater_write_key

   cd charts/env/prod/central-services/argocd
   helm dependency update
   helm upgrade --install argocd . --namespace argocd --create-namespace -f values.yaml
   ```

6. **One-time apply of the app-of-apps root Application** — after this,
   everything else (Karpenter, ALB controller, Crossplane, cert-manager
   addon config, greeter) is self-managing via git:
   ```bash
   kubectl apply -n argocd -f charts/env/prod/argocd-apps.yaml
   ```

7. **Delete the local key files** (`/tmp/argocd_deploy_key*`,
   `/tmp/image_updater_write_key*`) once both Secrets are confirmed
   created — they're only needed transiently.

8. **Validate** — see [Post-recovery checklist](#post-recovery-checklist)
   below. Expect DNS/ingress to take a few extra minutes even after
   everything reports `Healthy`: external-dns reconciles on a ~60s loop,
   and the ACM cert (if it also needed recreating) needs DNS validation
   to propagate.

**Estimated RTO:** 30-45 minutes for a clean rebuild with the hosted zone
intact and no unexpected `terraform apply` surprises. Add however long
DNS propagation takes if the zone itself also needed recreating (hours,
not minutes — see below).

## Scenario: Terraform state bucket lost

The state bucket (`hivemind-challenge-greeter-tfstate`) is versioned, so
an accidental `terraform destroy` or a bad apply is recoverable via S3
version history:

```bash
aws s3api list-object-versions --bucket hivemind-challenge-greeter-tfstate \
  --prefix envs/prod/terraform.tfstate --profile hivemind
# find the last-known-good VersionId, then:
aws s3api get-object --bucket hivemind-challenge-greeter-tfstate \
  --key envs/prod/terraform.tfstate --version-id <VersionId> \
  terraform.tfstate.recovered --profile hivemind
```

If the **bucket itself** is deleted (not just an object version), there
is no automatic recovery — versioning protects object history, not the
bucket's existence. In that case:

1. Re-run the bootstrap in `terraform/shared/terraform-backend/README.md`
   to recreate the bucket (new, empty).
2. Terraform now has a config that doesn't match reality — the real AWS
   resources (EKS cluster, IAM roles, etc.) still exist, but state
   describing them doesn't. Either:
   - **Import each resource** (`terraform import`, tedious but precise —
     the actual resource IDs are all real and discoverable via
     `aws eks describe-cluster`, `aws iam list-roles`, etc.), or
   - **Treat it as a full rebuild** (destroy the orphaned real resources
     by hand via the AWS console/CLI, then follow
     [Scenario: full cluster loss](#scenario-full-cluster-loss) for a
     clean `terraform apply` from nothing).

   Import is the right call for a handful of resources; past a certain
   point (this stack is ~170+ tracked resources once fully built out)
   a clean rebuild is genuinely faster and less error-prone than
   hand-importing everything correctly.

## Scenario: Route53 hosted zone lost

The zone was created out-of-band and isn't Terraform-managed, so this is
the one true single point of failure with no automated recovery path.

1. Recreate the public hosted zone:
   ```bash
   aws route53 create-hosted-zone --name hivemind.chaima.online \
     --caller-reference "$(date +%s)" --profile hivemind
   ```
2. **Re-delegate from the parent zone.** Take the 4 NS records from the
   new zone's `DelegationSet` and update them wherever `chaima.online`
   itself is managed (its own Route53 zone, or the registrar directly —
   not tracked in this repo). This step is entirely outside this repo's
   control and is the actual bottleneck: DNS delegation changes can take
   anywhere from minutes to ~48 hours to fully propagate depending on
   the parent zone's NS record TTL.
3. Update `terraform/envs/prod/variables.tf`'s `domain_name` default if
   the zone was recreated under a *different* name — otherwise no config
   change needed, `data "aws_route53_zone"` just looks it up by name.
4. Everything downstream (ACM cert validation, external-dns records)
   rebuilds itself automatically once the zone exists and is actually
   resolving — external-dns and the ACM validation flow both just retry
   on their own loops.

## Scenario: bad deploy / broken sync

Argo CD deployed something broken (a chart regression, a bad image tag).
This is a rollback, not a disaster-recovery event, but it's the most
common "something's wrong, what do I do" case:

```bash
# Find the last-good commit for the affected chart
git log --oneline -- charts/env/prod/apps/greeter

# Revert forward (never force-push/rewrite history on a repo Argo CD is
# actively watching — it just re-syncs to whatever's on the branch tip)
git revert <bad-commit>
git push origin main

# Argo CD's selfHeal picks it up within its poll interval, or force it:
kubectl annotate application greeter -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

For the greeter app specifically: Argo CD Image Updater owns
`image.tag` in `charts/env/prod/apps/greeter/values.yaml` going forward
(see `docs/DECISIONS.md` #11) — a bad image means fixing it upstream in
`hivemind-greeter` and cutting a new Release, not hand-editing the tag
here (Image Updater will just overwrite a hand-edit on its next cycle).

## Scenario: compromised credential

- **A git deploy key (read or write) leaked or is suspected
  compromised:** revoke it immediately (`gh repo deploy-key delete
  <id> --repo chayma1205/hivemind-challenge` or via GitHub Settings →
  Deploy keys), generate a new one, update the matching K8s Secret
  (`kubectl -n argocd delete secret <name>` then recreate as in step 4-5
  above). Argo CD picks up a new repo-server credential automatically;
  Image Updater's write-back will fail loudly (not silently) until its
  Secret is replaced.
- **The GitHub Actions OIDC role is suspected compromised:** there's no
  static key to rotate — revoke trust by deleting/tightening
  `module.github_actions_ecr_push_irsa`'s subject conditions in
  `terraform/envs/prod/github.tf` and `terraform apply`. Any in-flight
  workflow run loses access immediately on its next AWS API call.
- **An IAM role used by a Pod Identity association (external-dns,
  cert-manager, Crossplane) is suspected compromised:** the blast radius
  is bounded by design — each is scoped to one hosted zone or, for
  Crossplane, currently a placeholder (see `docs/DECISIONS.md`). Rotate
  by tainting and reapplying the specific `aws_iam_role` resource; the
  Pod Identity association re-binds to the new role automatically.

## Post-recovery checklist

Run through this after any recovery scenario before considering it done:

```bash
# Cluster and nodes healthy
kubectl get nodes

# All Argo CD Applications synced and healthy
kubectl get applications -n argocd

# DNS actually resolving (bypasses any local resolver flakiness)
aws route53 test-dns-answer --hosted-zone-id <zone-id> \
  --record-name greeter.hivemind.chaima.online --record-type A --profile hivemind

# End-to-end HTTPS actually works
curl -sk https://greeter.hivemind.chaima.online

# Metrics flowing (a real gap that's bitten this stack before — see
# docs/ASSESSMENT.md's "bugs found only by running the thing")
kubectl top nodes

# external-dns has no auth errors (the other bug from that same section —
# specifically check it's NOT falling back to the node IAM role)
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=20
```

If any of these fail, check `docs/ASSESSMENT.md`'s "Bugs found only by
running the thing" section first — several of the failure modes there
(wrong Pod Identity namespace, missing security group rule for
metrics-server) are exactly the kind of thing that reappears after a
from-scratch rebuild if the underlying Terraform fix isn't actually in
the state being applied.

## Known gaps (be honest about what this doesn't cover)

- **Single region, single AZ-spread within that region.** No
  cross-region DR. A `us-east-1` regional outage takes this down
  entirely, with no failover.
- **No automated backup testing.** The state-bucket-versioning recovery
  path and the import-vs-rebuild tradeoff above are documented but not
  regularly exercised — the first real test of this doc may be an actual
  incident.
- **No RPO/RTO commitment beyond best-effort.** This is a single-operator
  project, not a system with an on-call rotation or an SLA. The
  procedures above are written to be followable under pressure, not to
  hit a contracted recovery time.
- **The Route53 zone recreation path is the weakest link** in this whole
  document — it depends on delegation from a parent zone this repo has
  no visibility into or control over.
