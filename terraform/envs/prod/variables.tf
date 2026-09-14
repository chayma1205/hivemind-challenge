variable "aws_region" {
  description = "AWS region to provision prod resources in."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI/SDK profile (from ~/.aws/config) used to authenticate."
  type        = string
  default     = "hivemind"
}

variable "cluster_name" {
  description = "Name of the EKS cluster; also used as a prefix for related resources."
  type        = string
  default     = "hivemind-prod"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway instead of one per AZ (cheaper, less HA)."
  type        = bool
  default     = false
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the greeter application image."
  type        = string
  default     = "hivemind-greeter"
}

variable "github_owner" {
  description = "GitHub account this cluster's CI/CD pipeline runs from."
  type        = string
  default     = "chayma1205"
}

variable "github_owner_id" {
  description = "Numeric GitHub account ID for github_owner (`gh api users/<owner> --jq .id`) — GitHub's OIDC \"immutable subject\" format (default for repos created after 2026-07-15) keys on this, not the account name."
  type        = string
  default     = "2427500"
}

variable "github_repo" {
  description = "GitHub repository name (without the owner) this cluster's CI/CD pipeline runs from."
  type        = string
  default     = "hivemind-challenge"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID (`gh api repos/<owner>/<repo> --jq .id`) — see github_owner_id."
  type        = string
  default     = "1370459474"
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the default managed node group."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes in the default managed node group."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of nodes in the default managed node group."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all resources in this stack."
  type        = map(string)
  default = {
    Project     = "hivemind"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
