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

output "karpenter_iam_role_arn" {
  description = "IRSA role ARN for the Karpenter controller — set in the karpenter chart's serviceAccount.annotations."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_iam_role_name" {
  description = "IAM role name Karpenter-launched EC2 nodes assume — set in the karpenter chart's nodePool.nodeRoleName."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter spot interruption handling — set in the karpenter chart's settings.interruptionQueue."
  value       = module.karpenter.queue_name
}

output "aws_load_balancer_controller_iam_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller — set in that chart's serviceAccount.annotations."
  value       = module.aws_load_balancer_controller_irsa.iam_role_arn
}

output "cert_manager_iam_role_arn" {
  description = "IRSA role ARN for cert-manager's Route53 DNS-01 solver — set in that chart's serviceAccount.annotations."
  value       = module.cert_manager_irsa.iam_role_arn
}

output "argocd_image_updater_iam_role_arn" {
  description = "IRSA role ARN for argocd-image-updater's ECR read access — set in that chart's serviceAccount.annotations."
  value       = module.argocd_image_updater_irsa.iam_role_arn
}

output "github_actions_ecr_push_role_arn" {
  description = "OIDC role ARN GitHub Actions assumes to push to ECR — set as AWS_ROLE_ARN in .github/workflows/cd.yml."
  value       = module.github_actions_ecr_push_irsa.arn
}
