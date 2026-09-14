terraform {
  # >= 1.11 is required so that `envs/*` stacks can rely on the S3 backend's
  # native `use_lockfile` state locking instead of a DynamoDB lock table.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # This stack provisions the bucket every other stack uses as its remote
  # backend, so it cannot use that backend itself (chicken-and-egg). Its own
  # state is kept local; see README.md for how to bootstrap and safeguard it.
}
