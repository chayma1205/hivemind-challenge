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

# cosign signatures/attestations (SBOM, SLSA provenance) for the greeter
# image, pushed by the CI/CD pipeline in the hivemind-greeter repo's
# _build-push.yml. A separate repo, not a `:sha.sig`-style tag in
# ecr_greeter above, because cosign rewrites its .sig/.att tags in place —
# incompatible with ecr_greeter's IMMUTABLE tag mutability.
module "ecr_signatures" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 2.3"

  repository_name = var.ecr_signatures_repository_name

  repository_image_tag_mutability = "MUTABLE"
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

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access      = true

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
      addon_version               = "v1.23.1-eksbuild.1"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      addon_version               = "v1.14.3-eksbuild.23"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      addon_version               = "v1.36.0-eksbuild.25"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    eks-pod-identity-agent = {
      addon_version               = "v1.4.0-eksbuild.2"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # Same system-node-group pinning as cert-manager below. Route53
    # permissions come from the Pod Identity association in domain.tf.
    external-dns = {
      addon_version               = "v0.21.0-eksbuild.10"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        # Only ever touch this zone, and never delete records — upsert-only
        # is the safe default for a shared zone; txtOwnerId marks records
        # this cluster owns.
        domainFilters = [var.domain_name]
        policy        = "upsert-only"
        txtOwnerId    = var.cluster_name
        nodeSelector  = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      })
    }
    metrics-server = {
      addon_version               = "v0.9.0-eksbuild.11"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        replicas     = 2
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      })
    }
    # Pinned to the newest published version for cluster_version (1.36) as
    # of 2026-09-22 — check
    # `aws eks describe-addon-versions --addon-name <name> --kubernetes-version 1.36`
    # before bumping, rather than tracking "latest" implicitly. vpc-cni and
    # eks-pod-identity-agent are one step ahead of AWS's flagged default
    # (v1.22.4-eksbuild.3 / v1.3.10-eksbuild.3); the rest are the default.
    cert-manager = {
      addon_version               = "v1.21.2-eksbuild.1"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        replicaCount = 2
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
        webhook = {
          replicaCount = 2
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
        cainjector = {
          replicaCount = 2
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
      })
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
