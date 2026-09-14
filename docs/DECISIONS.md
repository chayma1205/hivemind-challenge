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
