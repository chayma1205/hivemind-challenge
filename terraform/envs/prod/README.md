# envs/prod

Provisions the production infrastructure for the greeter app: a VPC, an ECR
repository for the container image, and an EKS cluster — all via
[terraform-aws-modules](https://registry.terraform.io/namespaces/terraform-aws-modules)
community modules.

| Resource | Module | Purpose |
|---|---|---|
| VPC | `terraform-aws-modules/vpc/aws` | 3-AZ VPC with public + private subnets, NAT gateway(s) |
| ECR | `terraform-aws-modules/ecr/aws` | Image repository for the greeter app, scan-on-push, lifecycle policy |
| EKS | `terraform-aws-modules/eks/aws` | Kubernetes cluster running the greeter service across AZs |

## Prerequisites

1. The remote state bucket must already exist — apply
   [`terraform/shared/terraform-backend`](../../shared/terraform-backend) first.
2. `bucket` in [`backend.tf`](backend.tf) must match that bucket's name (default: `hivemind-challenge-tfstate`).
3. AWS credentials available under the `hivemind` profile (`~/.aws/config` / `~/.aws/credentials`), or override `aws_profile`.

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
* The EKS public endpoint is open (`cluster_endpoint_public_access = true`); restrict with `cluster_endpoint_public_access_cidrs` or switch to private-only + a bastion/VPN in a real environment.
* State locking uses the S3 backend's native `use_lockfile` (Terraform >= 1.11) — no DynamoDB table.
