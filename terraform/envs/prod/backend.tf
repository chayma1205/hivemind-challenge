# Backend values can't reference variables, so they're hardcoded here to
# match the bucket created by terraform/shared/terraform-backend. Override
# per-operator with `terraform init -backend-config=...` if needed.
terraform {
  backend "s3" {
    bucket  = "hivemind-greeter-tfstate"
    key     = "envs/prod/terraform.tfstate"
    region  = "us-east-1"
    profile = "hivemind"
    encrypt = true

    # Native S3 state locking (Terraform >= 1.11) via conditional writes.
    # No DynamoDB lock table is used or required.
    use_lockfile = true
  }
}
