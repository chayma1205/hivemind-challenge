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
