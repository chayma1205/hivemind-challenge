# envs/prod

Provisions the production infrastructure for the greeter app: a VPC, two
ECR repositories (the app image + cosign signatures), an EKS cluster,
domain/TLS wiring, and the IAM/Pod Identity roles every cluster add-on
needs — all via
[terraform-aws-modules](https://registry.terraform.io/namespaces/terraform-aws-modules)
community modules plus this stack's own resources.

| Resource | Module | Purpose |
|---|---|---|
| VPC | `terraform-aws-modules/vpc/aws` | 3-AZ VPC with public + private subnets, NAT gateway(s) |
| ECR | `terraform-aws-modules/ecr/aws` | Image repos for the greeter app (immutable tags) and its cosign signatures (mutable tags) |
| EKS | `terraform-aws-modules/eks/aws` | Kubernetes cluster running the greeter service across AZs |

See [`domain.tf`](domain.tf) for the Route53/ACM/Pod Identity wiring and
[`github.tf`](github.tf)/[`iam.tf`](iam.tf) for the OIDC and IRSA/Pod
Identity roles — not covered by the table above since they're this
stack's own resources, not community modules.

## Prerequisites

1. The remote state bucket must already exist — apply
   [`terraform/shared/terraform-backend`](../../shared/terraform-backend) first.
2. `bucket` in [`backend.tf`](backend.tf) must match that bucket's name (default: `hivemind-challenge-greeter-tfstate`).
3. The `hivemind.chaima.online` Route53 hosted zone must already exist —
   it's out-of-band, not created by this stack (see
   `data "aws_route53_zone"` in `domain.tf`).
4. AWS credentials available under the `hivemind` profile (`~/.aws/config` / `~/.aws/credentials`), or override `aws_profile`.

## Usage

```bash
cd terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars   # adjust as needed
terraform init
terraform plan
terraform apply
```

Configure `kubectl` against the new cluster (also printed as the
`configure_kubectl` output):

```bash
aws eks update-kubeconfig --region us-east-1 --name hivemind-prod --profile hivemind
```

## Notes / production tradeoffs

* `single_nat_gateway = false` by default for AZ-level HA; set to `true` to cut NAT gateway cost at the expense of a single point of failure.
* `enable_cluster_creator_admin_permissions = true` grants the applying identity cluster-admin via EKS access entries — convenient for bootstrapping, but production access should move to scoped IAM roles/RBAC.
* The EKS public endpoint is restricted to `cluster_endpoint_public_access_cidrs` (a single operator IP by default, not `0.0.0.0/0`) — still a static allowlist, not a VPN/bastion; revisit if more than one operator needs access (see `docs/DECISIONS.md` #6).
* State locking uses the S3 backend's native `use_lockfile` (Terraform >= 1.11) — no DynamoDB table.
