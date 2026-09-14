provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# Remote state bucket shared by every stack under terraform/envs/*.
#
# Locking: no DynamoDB table is provisioned here. Consuming stacks enable
# `use_lockfile = true` on their `backend "s3"` block, which uses S3
# conditional writes (Terraform >= 1.11) for native state locking, so a
# separate lock table is unnecessary.
module "terraform_state" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1"

  bucket = var.bucket_name

  force_destroy = false

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_policy = true
  policy        = data.aws_iam_policy_document.deny_insecure_transport.json

  tags = var.tags
}

data "aws_iam_policy_document" "deny_insecure_transport" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      "arn:aws:s3:::${var.bucket_name}",
      "arn:aws:s3:::${var.bucket_name}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
