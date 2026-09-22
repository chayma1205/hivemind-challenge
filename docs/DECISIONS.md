# Architecture Decision Records

Lightweight ADR log for this repo. Each entry: context, decision,
consequences/tradeoffs.

## 1. Terraform with community modules, not hand-rolled resources

**Context:** VPC/EKS/ECR each involve dozens of interdependent resources
(subnets, route tables, IAM roles, security groups, OIDC providers, ...).

**Decision:** Use the `terraform-aws-modules/{vpc,eks,ecr,s3-bucket}/aws`
modules rather than writing every resource by hand.

**Consequences:** Far less code to write and review, and these modules
encode AWS/EKS best practices (subnet tagging, IRSA OIDC setup, etc.) that
would otherwise need to be rediscovered. Tradeoff: less low-level control,
and the module's opinions have to be understood before overriding them.

## 2. S3 backend with native locking, no DynamoDB table

**Context:** Terraform state needs remote storage and locking so concurrent
`apply` runs can't corrupt it. The traditional pattern is an S3 bucket +
DynamoDB lock table.

**Decision:** Use the S3 backend's native `use_lockfile = true` (GA in
Terraform ≥ 1.11), which locks via S3 conditional writes. No DynamoDB table
is provisioned.

**Consequences:** One fewer resource to provision, pay for, and secure;
locking lives in the same place as the state. Tradeoff: requires every
operator/CI runner to use Terraform ≥ 1.11 — older CLIs silently ignore
`use_lockfile` and lose locking, so this is enforced via
`required_version = ">= 1.11"` in both stacks.

## 3. A separate bootstrap stack for the backend itself

**Context:** The S3 bucket that stores Terraform state can't itself be
managed by a stack whose state lives in that same bucket (chicken-and-egg).

**Decision:** Split the repo into `terraform/shared/terraform-backend`
(local state, run once to bootstrap) and `terraform/envs/prod` (remote
state, in the bucket the bootstrap stack created).

**Consequences:** Clean separation, but the bootstrap stack's local state
file is a manually-safeguarded exception to "everything is remote state" —
documented in its README rather than hidden.

## 4. EKS managed node groups, not Fargate

**Context:** EKS supports EC2-backed managed node groups or serverless
Fargate profiles for running pods.

**Decision:** Use a managed node group (`t3.medium`, on-demand, 2-4 nodes)
across 3 AZs.

**Consequences:** Predictable cost/performance and full node-level control
(DaemonSets, host networking) if needed later. Tradeoff: nodes are always
running (vs. Fargate's pay-per-pod), and node patching/AMI upgrades are the
operator's responsibility rather than AWS's. For a workload this small,
Fargate would also be a reasonable choice — revisit if idle-cost matters
more than flexibility.

## 5. NAT gateway per AZ by default

**Context:** Private subnets need NAT for outbound internet access (pulling
images, calling AWS APIs). A NAT gateway can be shared across all AZs or
one deployed per AZ.

**Decision:** Default to `single_nat_gateway = false` (one NAT gateway per
AZ).

**Consequences:** An AZ outage doesn't take down egress for the other AZs —
consistent with the "highly available" requirement. Tradeoff: ~3x the NAT
gateway cost of a single shared gateway; `single_nat_gateway` is exposed as
a variable so this can be flipped for cost-sensitive/non-prod use.

## 6. Public EKS API endpoint

**Context:** The EKS control plane endpoint can be public, private, or
both.

**Decision:** `cluster_endpoint_public_access = true` (alongside private
access) so the cluster is reachable without a bastion/VPN.

**Consequences:** Straightforward to operate for this challenge. In a real
production environment this should be restricted via
`cluster_endpoint_public_access_cidrs` or moved to private-only access
behind a VPN/bastion/Session Manager — called out in the prod stack's
README as a known gap rather than silently accepted.

**Revisited (2026-09-22):** `cluster_endpoint_public_access_cidrs` is now
set, restricting the public endpoint to the operator's IP rather than
`0.0.0.0/0`. Still a static single-IP allowlist, not a VPN/bastion — worth
revisiting again if more than one operator ever needs access, since the
CIDR has no mechanism to stay current on its own (see the `TODO` next to
it in `variables.tf`).

## 7. Region `us-east-1`, AWS profile `hivemind`

**Context:** Needed a concrete region/credentials story for a runnable
example.

**Decision:** Default `aws_region = "us-east-1"` and `aws_profile =
"hivemind"`, both overridable via variables (and `-backend-config` for the
backend block, which can't read variables).

**Consequences:** Works out of the box for this environment; anyone using a
different profile/region only needs to override the two variables (and the
hardcoded values in `backend.tf`, since backend configuration can't
reference variables).

## 8. Immutable ECR tags + scan-on-push

**Context:** Mutable tags (e.g. re-pushing `:latest`) make it impossible to
know what's actually running, and image vulnerabilities can go unnoticed.

**Decision:** `repository_image_tag_mutability = "IMMUTABLE"` and
`repository_image_scan_on_push = true`.

**Consequences:** Every deployed tag is traceable to exactly one image
build; CI must produce a new tag per build (e.g. git SHA) rather than
reusing `:latest`. Scanning surfaces known CVEs in the image without an
extra tool.

## 9. EKS on Kubernetes 1.36

**Context:** Needed a supported, current Kubernetes version.

**Decision:** Default `cluster_version = "1.36"`, the newest version EKS
supports as of this writing (September 2026).

**Consequences:** Longest runway before the version reaches end of standard
support. Tradeoff: newest versions have had the least real-world soak time;
pin to an older supported version (e.g. `1.33`) if that matters more than
runway for a given deployment.

## 10. This GitHub repo is public → revisited: made private

**Context:** Argo CD needs to clone this repo to sync
[`charts/env/prod/argocd-apps.yaml`](../charts/env/prod/argocd-apps.yaml).
A private repo means Argo CD needs a stored credential (a GitHub PAT in a
Kubernetes Secret) — an extra moving part, and one that (in the environment
this was built in) needed a human to create directly, since an AI agent
writing credentials into a cluster is exactly the kind of action worth a
human in the loop rather than full automation.

**Original decision:** Make the repo public instead. Verified beforehand
that nothing sensitive is committed — no tokens/keys, just resource names,
non-secret config, and an AWS account ID (not itself a credential).

**Original consequences:** Argo CD clones over plain HTTPS with zero
credentials — no Secret, no `argocd repo add`, no rotation to think about.
Tradeoff: the repo (code, infra structure, resource-naming conventions) is
visible to anyone.

**Revisited (2026-09-22):** The repo was made private. Exactly the
tradeoff flagged above as the trigger to revisit this: the app's source
moved to its own repo ([`hivemind-greeter`](https://github.com/chayma1205/hivemind-greeter),
see decision #11), and at that point there was no more reason for the
remaining GitOps-only repo to stay world-readable by default.

**Decision:** A scoped SSH deploy-key Secret, per the original tradeoff
note — not a PAT, not an OIDC-based credential. Two separate keys, both
created as a manual bootstrap step (same human-in-the-loop reasoning as
above, unchanged):

* **Read-only**, for Argo CD's repo-server to clone/sync — see
  [`charts/env/prod/central-services/argocd/README.md`](../charts/env/prod/central-services/argocd/README.md#repository-access-private-repo).
* **Write**, for Argo CD Image Updater's git write-back (bumping
  `greeter`'s image tag) — a separate key so a compromised sync credential
  can't also push commits; see
  [`charts/env/prod/central-services/argocd-image-updater/README.md`](../charts/env/prod/central-services/argocd-image-updater/README.md).

**Consequences:** Both keys are repo-scoped (GitHub deploy keys, not
account-wide PATs) and the read path/write path are fully separated.
Tradeoff: two credentials to rotate instead of zero: an accepted cost of
no longer being public.

## 11. CI/CD: two workflows, OIDC, GitOps hand-off — not a direct deploy → revisited: split into two repos, Image Updater hand-off

**Context:** Needed a pipeline to build, scan, and ship the greeter image
on every merge to `main`, without reintroducing the problems the rest of
this repo was built to avoid (long-lived AWS keys, a pipeline that can
silently deploy without passing CI, direct cluster credentials sitting in
GitHub).

**Original decision:** Two separate workflows, not one, both living here
alongside `app/`:

* `ci.yml` ran on every PR and push to `main`, needed no AWS access at
  all, and never pushed an image anywhere — it only built (locally,
  discarded after) and scanned.
* `cd.yml` triggered via `workflow_run` *after* `ci.yml` succeeded on
  `main`, authenticated to AWS via GitHub's OIDC provider
  (`module.github_actions_ecr_push_irsa`), and stopped at committing the
  new tag into `argocd-params.env`; Argo CD (already watching this repo)
  did the actual deploy.

**Revisited (2026-09-22):** The greeter app's source moved to its own
repo, [`hivemind-greeter`](https://github.com/chayma1205/hivemind-greeter)
— `app/` no longer exists here. This repo is GitOps-only now: charts,
`argocd-apps.yaml`, and Terraform. Consequences for what was decided
above:

* `cd.yml` (here) is **deleted** — there's nothing left for it to build.
* `ci.yml` (here) is trimmed to `helm-lint` on the greeter chart plus a
  check that `argocd-apps.yaml` is up to date with the chart directories
  — the only things left in this repo worth validating on every push.
* `module.github_actions_ecr_push_irsa`'s OIDC trust
  (`terraform/envs/prod/github.tf`) now points at `hivemind-greeter`
  (`var.github_repo`/`var.github_repo_id`), not this repo — that's where
  the OIDC-authenticated push actually happens now, via that repo's own
  `_build-push.yml` (shared by its `main`, `releases/**`, and Release-tag
  triggers). Also added `module.ecr_signatures`
  (`hivemind-greeter-signatures`, MUTABLE) for that pipeline's cosign
  signature/SBOM/provenance attestations — cosign rewrites `.sig`/`.att`
  tags in place, incompatible with `ecr_greeter`'s IMMUTABLE tags.
* **The git commit-back step is gone.** Instead of `cd.yml` hand-editing
  `argocd-params.env` after every push to `main`, prod now only moves on
  a **published GitHub Release** (`vX.Y.Z` tag) in `hivemind-greeter`.
  Argo CD Image Updater (`charts/env/prod/central-services/argocd-image-updater`,
  its `ImageUpdater` CR in `templates/imageupdater.yaml`) watches ECR for
  tags matching that shape and writes the new `image.tag` directly into
  `charts/env/prod/apps/greeter/values.yaml` via its own git write-back —
  no CI workflow in either repo touches this repo's git history for a
  routine deploy anymore.

**Consequences:** Slower, deliberate promotion to prod (a Release, not
every merge) instead of continuous deploy on every `main` push — a
tradeoff accepted because "cut a Release" is an explicit, auditable human
action, and because `hivemind-greeter`'s `main`/`releases/**` branches
still get commit-SHA/staging-tagged images pushed to ECR (via `cd.yml`/
`cd-staging.yml` there) without ever reaching prod, giving a real
promotion gate. The OIDC role and least-privilege ECR push scoping from
the original decision are unchanged, just re-pointed at the repo that
actually needs them now. Image Updater's write-back needs its own
**write**-scoped git credential, separate from Argo CD's own read-only
sync credential (see decision #10) — a new moving part, but one that
keeps the sync path read-only even though the deploy path can now push.
