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

variable "ecr_signatures_repository_name" {
  description = "Name of the ECR repository cosign pushes signature/attestation/provenance artifacts to for the greeter image. MUTABLE (unlike ecr_repository_name): cosign rewrites its .sig/.att tags in place."
  type        = string
  default     = "hivemind-greeter-signatures"
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
  description = "GitHub repository (without the owner) this cluster's image build/push CI/CD pipeline runs from. The greeter app's source (and its ci/cd workflows) live in a separate repo from this GitOps repo (hivemind-challenge) — see docs/DECISIONS.md #11."
  type        = string
  default     = "hivemind-greeter"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID for github_repo (`gh api repos/<owner>/<repo> --jq .id`) — see github_owner_id."
  type        = string
  default     = "1379362394"
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group."
  type        = list(string)
  default     = ["t3.large"]
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

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint. Defaults to the operator's own IP at the time this was set; update if your IP changes."
  type        = list(string)
  default     = ["93.244.115.182/32"]
}

variable "domain_name" {
  description = "Domain name external-dns manages records in and cert-manager issues certificates for. A Route53 public hosted zone for this exact name must already exist (see domain.tf)."
  type        = string
  default     = "hivemind.chaima.online"
}

variable "alert_email" {
  description = "Email address subscribed to the Alertmanager SNS topic (see observability.tf). SNS emails a confirmation link to this address on first apply — a real, one-time manual step (click it), the same class of thing as this stack's other human-in-the-loop steps (docs/DECISIONS.md #10)."
  type        = string
  default     = "chaima.ben.haha.it@gmail.com"
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
