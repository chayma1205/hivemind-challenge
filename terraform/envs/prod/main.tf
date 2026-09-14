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
    # Lets Karpenter discover subnets to launch nodes into — matches
    # charts/env/prod/critical/karpenter's EC2NodeClass.subnetSelectorTerms.
    "karpenter.sh/discovery" = var.cluster_name
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

  # Pinned to the AWS-recommended default version for cluster_version
  # (1.36) as of this writing — check
  # `aws eks describe-addon-versions --addon-name <name> --kubernetes-version 1.36`
  # before bumping, rather than tracking "latest" implicitly.
  cluster_addons = {
    vpc-cni = {
      addon_version               = "v1.22.4-eksbuild.3"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      addon_version               = "v1.14.3-eksbuild.16"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      addon_version               = "v1.36.0-eksbuild.21"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  # Lets Karpenter discover this security group for nodes it launches —
  # matches charts/env/prod/critical/karpenter's
  # EC2NodeClass.securityGroupSelectorTerms.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

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

  # iam:ListInstanceProfiles doesn't support resource-level scoping (must
  # be Resource "*"), so the module's own scoped-to-instance-profile/*
  # statements never cover it — its periodic instance-profile garbage
  # collection controller 403s without this.
  iam_policy_statements = [
    {
      sid       = "AllowInstanceProfileListAction"
      effect    = "Allow"
      actions   = ["iam:ListInstanceProfiles"]
      resources = ["*"]
    }
  ]

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

# IRSA for cert-manager's Route53 DNS-01 solver. Fills the prerequisite
# documented in charts/env/prod/critical/cert-manager/values.yaml — that
# chart's serviceAccount.annotations should be set to this module's
# iam_role_arn output.
module "cert_manager_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-cert-manager"

  attach_cert_manager_policy = true
  # TODO: narrow to the specific hosted zone ARN once a real domain/Route53
  # hosted zone exists; left at the module's own default (all hosted zones
  # in the account) since none exists yet.

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  tags = var.tags
}

# IRSA for argocd-image-updater (ECR read access to detect new image tags).
# Fills the prerequisite documented in
# charts/env/prod/central-services/argocd-image-updater/values.yaml.
module "argocd_image_updater_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.cluster_name}-argocd-image-updater"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["argocd:argocd-image-updater"]
    }
  }

  tags = var.tags
}

# No attach_* flag exists for plain ECR read access in the module, so
# attach the AWS managed policy directly.
resource "aws_iam_role_policy_attachment" "argocd_image_updater_ecr_read" {
  role       = module.argocd_image_updater_irsa.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

################################################################################
# GitHub Actions OIDC — lets the .github/workflows/cd.yml pipeline push to
# ECR with short-lived, per-run credentials instead of a long-lived AWS
# access key stored as a repo secret.
################################################################################

module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "~> 5.39"

  tags = var.tags
}

# Scoped to pushes on `main` only. Uses GitHub's newer "immutable subject
# claims" format (repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:...) rather than
# the older name-only repo:owner/repo:ref:... form — repos created after
# 2026-07-15 (this one included) get this format by default, and the
# name-only pattern silently never matches for them (confirmed by a real
# failed AssumeRoleWithWebIdentity call against the old format, not just
# a guess). IDs via `gh api repos/<owner>/<repo> --jq
# '{owner_id:.owner.id, repo_id:.id}'`; they don't change even if the repo
# or account is later renamed.
module "github_actions_ecr_push_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-role"
  version = "~> 5.39"

  name = "${var.cluster_name}-github-actions-ecr-push"

  subjects = [
    "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:ref:refs/heads/main",
  ]

  policies = {
    ecr_push = aws_iam_policy.github_actions_ecr_push.arn
  }

  tags = var.tags

  depends_on = [module.github_oidc_provider]
}

data "aws_iam_policy_document" "github_actions_ecr_push" {
  # ECR's auth token endpoint has no resource-level permissions.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushToGreeterRepoOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [module.ecr_greeter.repository_arn]
  }
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name        = "${var.cluster_name}-github-actions-ecr-push"
  description = "Push-only access to the greeter ECR repo, for CI/CD via GitHub OIDC"
  policy      = data.aws_iam_policy_document.github_actions_ecr_push.json
  tags        = var.tags
}
