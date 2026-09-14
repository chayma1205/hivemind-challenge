data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 3)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required so the AWS Load Balancer Controller / EKS can auto-discover
  # subnets for public and internal load balancers.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}

module "ecr_greeter" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.3"

  repository_name = var.ecr_repository_name

  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep the last 20 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })

  repository_force_delete = false

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Grants the caller running `terraform apply` cluster-admin via EKS access
  # entries, so the cluster is usable immediately without manual aws-auth
  # edits.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = var.node_instance_types
  }

  eks_managed_node_groups = {
    default = {
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      # Spread across AZs for HA.
      subnet_ids = module.vpc.private_subnets

      # Reserved for cluster-critical / central-services workloads (Argo CD,
      # Karpenter, the ALB controller — see charts/env/prod/critical and
      # charts/env/prod/central-services). Their charts pin themselves here
      # via nodeSelector `role: system` + a toleration for this taint. Once
      # Karpenter is healthy it should own general workload capacity
      # instead of this node group.
      labels = {
        role = "system"
      }

      taints = {
        critical-addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = var.tags
}

# IRSA for Karpenter's controller, plus the IAM role Karpenter-launched EC2
# nodes assume and the SQS queue/EventBridge rules for interruption
# handling. Fills the gaps documented as TODOs in
# charts/env/prod/critical/karpenter/values.yaml — that chart's
# serviceAccount.annotations and nodePool.nodeRoleName should be set to
# this module's iam_role_arn / node_iam_role_name outputs.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  # Karpenter 1.x IAM permission set (module defaults to the older
  # v0.33-v0.37 shape) — must match the chart's pinned appVersion (1.14.1).
  enable_v1_permissions = true

  # Fixed (non-random-suffixed) names so the ARNs hardcoded into
  # charts/env/prod/critical/karpenter/values.yaml stay valid across
  # applies instead of drifting on every replacement.
  iam_role_name              = "${var.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix   = false
  iam_policy_use_name_prefix = false

  # Role EC2 instances Karpenter launches assume; referenced by the
  # karpenter chart's EC2NodeClass.spec.role, not an instance profile (v1
  # Karpenter creates/manages instance profiles itself).
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  enable_spot_termination = true

  tags = var.tags
}

# IRSA for the AWS Load Balancer Controller. Fills the TODO documented in
# charts/env/prod/critical/aws-load-balancer-controller/values.yaml —
# that chart's serviceAccount.annotations should be set to this module's
# iam_role_arn output.
module "aws_load_balancer_controller_irsa" {
  # v5.x, not v6.x: v6's iam-role-for-service-accounts submodule requires
  # aws provider >= 6.28, which conflicts with the eks module (~> 20.31)
  # and its karpenter submodule above, both pinned to aws < 6.0.
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-aws-load-balancer-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = var.tags
}
