output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "IDs of the private subnets (EKS nodes/pods)."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "IDs of the public subnets (load balancers, NAT gateways)."
  value       = module.vpc.public_subnets
}

output "ecr_repository_url" {
  description = "URL of the ECR repository for the greeter image."
  value       = module.ecr_greeter.repository_url
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint of the EKS cluster's Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64-encoded certificate data for the EKS cluster."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --profile ${var.aws_profile}"
}
