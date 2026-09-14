# terraform-backend

Bootstrap stack that provisions the S3 bucket used as the remote state
backend for every other stack in this repo (currently `terraform/envs/prod`).

Uses the [`terraform-aws-modules/s3-bucket/aws`](https://registry.terraform.io/modules/terraform-aws-modules/s3-bucket/aws/latest)
community module with:

* Versioning enabled, so a corrupted/overwritten state file can be recovered.
* Default server-side encryption (SSE-KMS).
* All public access blocked.
* A bucket policy denying any request made without TLS.

## Locking without DynamoDB

No DynamoDB lock table is created. Instead, consuming stacks turn on the S3
backend's native locking (`use_lockfile = true`), which uses S3 conditional
writes to lock state — available as GA behavior from Terraform **1.11**
onwards. This removes the need to provision, pay for, and maintain a
DynamoDB table just for locking.

## Bootstrapping

This stack manages the backend that other stacks depend on, so it can't use
that backend itself — the classic chicken-and-egg problem. Its own state is
kept **local** (no `backend` block). Treat `terraform.tfstate` here as
sensitive: back it up, and consider moving it to a separately managed,
tightly-restricted bucket once the team grows past a single operator.

```bash
cd terraform/shared/terraform-backend
cp terraform.tfvars.example terraform.tfvars   # edit bucket_name if needed
terraform init
terraform apply
```

Take note of the `state_bucket_id` output — it must match the `bucket` value
used in `terraform/envs/prod/backend.tf`.
