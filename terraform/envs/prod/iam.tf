# IRSA for Karpenter's controller, plus the IAM role Karpenter-launched EC2
# nodes assume and the SQS queue/EventBridge rules for interruption
# handling. This module's iam_role_arn / node_iam_role_name outputs are
# copied into charts/env/prod/critical/karpenter/values.yaml's
# serviceAccount.annotations and nodePool.nodeRoleName respectively.
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

# IRSA for the AWS Load Balancer Controller. This module's iam_role_arn
# output is copied into
# charts/env/prod/critical/aws-load-balancer-controller/values.yaml's
# serviceAccount.annotations.
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

# cert-manager's Route53 DNS-01 solver permissions live in domain.tf as an
# EKS Pod Identity association, not here — the cert-manager EKS addon
# (cluster_addons.cert-manager in main.tf) exposes no serviceAccount
# config surface to set IRSA annotations on, so OIDC-based IRSA (this
# module's usual pattern, see aws_load_balancer_controller_irsa above)
# isn't wireable for it.

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
