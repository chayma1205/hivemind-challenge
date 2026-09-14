output "state_bucket_id" {
  description = "Name of the S3 bucket holding Terraform state."
  value       = module.terraform_state.s3_bucket_id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket holding Terraform state."
  value       = module.terraform_state.s3_bucket_arn
}

output "state_bucket_region" {
  description = "Region of the S3 bucket holding Terraform state."
  value       = var.aws_region
}
