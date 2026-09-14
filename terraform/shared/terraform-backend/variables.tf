variable "aws_region" {
  description = "AWS region to provision the Terraform backend bucket in."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI/SDK profile (from ~/.aws/config) used to authenticate."
  type        = string
  default     = "hivemind"
}

variable "bucket_name" {
  description = "Globally-unique name of the S3 bucket used to store Terraform state for all stacks."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources created by this stack."
  type        = map(string)
  default = {
    Project   = "hivemind"
    ManagedBy = "terraform"
    Stack     = "terraform-backend"
  }
}
