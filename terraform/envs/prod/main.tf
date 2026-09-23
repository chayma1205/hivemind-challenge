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
    # Bundles BOTH the base Secrets Store CSI Driver and the AWS provider
    # (confirmed via `aws eks describe-addon-configuration` — its config
    # schema has a nested `secrets-store-csi-driver` key, and upstream's
    # own README: "Helm chart for the ASCP by default automatically
    # installs a compatible version of the Secrets Store CSI driver").
    # No nodeSelector/tolerations override here, unlike the other addons
    # below: this runs as a DaemonSet (a CSI plugin has to be on every
    # node that might mount a secret, not just the system node group),
    # and the schema's own default (`tolerations: [{operator: Exists}]`)
    # already covers that correctly.
    #
    # No IAM/Pod Identity role provisioned for it here, deliberately: the
    # provider reads Secrets Manager/SSM using each *consuming* pod's own
    # IRSA or Pod Identity role, passed through via its service account
    # token — not a shared identity of its own (confirmed against
    # upstream's README, "Option 2: Using EKS Pod Identity", which has
    # each workload create its *own* role). A workload that wants to
    # mount a secret needs its own aws_eks_pod_identity_association
    # scoped to just that secret's ARN, the same least-privilege pattern
    # as every other Pod Identity role in this stack — plus a
    # SecretProviderClass and a matching volume mount, neither of which
    # exist yet for any workload (greeter doesn't use any secrets today).
    aws-secrets-store-csi-driver-provider = {
      addon_version               = "v3.1.3-eksbuild.1"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        awsRegion = var.aws_region
      })
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
    # Prerequisite for persistent storage (PersistentVolumeClaims backed by
    # EBS) — nothing in this cluster needed it before now. Pod Identity
    # association + IAM role below, same pattern as every other addon
    # here; role ARN wired via configuration_values since the addon's own
    # schema takes it directly, unlike the Pod-Identity-only addons above
    # that pick up their association purely by namespace/service-account
    # match.
    aws-ebs-csi-driver = {
      addon_version               = "v1.66.0-eksbuild.1"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        controller = {
          replicaCount = 2
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
        # node daemonset is left at its schema default (tolerations:
        # [{operator: Exists}]) — it has to run on every node that might
        # mount an EBS volume, not just the system group.
      })
    }
  }

  # Lets Karpenter discover this security group for nodes it launches —
  # matches charts/env/prod/critical/karpenter's
  # EC2NodeClass.securityGroupSelectorTerms.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # The module's default node security group rules cover the control
  # plane's usual webhook ports (443/4443/6443/8443/9443) and kubelet
  # (10250), but not metrics-server's own aggregated-API port (10251) —
  # confirmed live: the v1beta1.metrics.k8s.io APIService couldn't
  # register (control plane timed out connecting to the metrics-server
  # pod on 10251), which cascaded into every HPA reporting
  # `<unknown>` targets and, from there, into Argo CD marking any
  # Application with an HPA (argocd itself, greeter) as Degraded.
  node_security_group_additional_rules = {
    ingress_cluster_metrics_server = {
      description                   = "Cluster API to node metrics-server webhook/aggregated API"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
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

# Pod Identity role for the aws-ebs-csi-driver addon above. Same
# iam-assumable-role / role_requires_mfa=false pattern as
# domain.tf's Pod Identity roles (see that file's comment on
# module "external_dns_pod_identity" for why role_requires_mfa must be
# false) — kept here rather than domain.tf since this has nothing to do
# with the hosted zone/DNS, it's core cluster storage plumbing.
#
# AmazonEBSCSIDriverPolicyV2 (AWS-managed, not hand-rolled): this is
# exactly the kind of broad-but-well-maintained policy worth using
# as-is — EBS volume lifecycle (create/attach/detach/delete/snapshot)
# needs permissions across arbitrary future volume/snapshot IDs that
# don't exist yet at plan time, so there's no useful narrower resource
# scope to hand-write, and AWS keeps this policy current as the driver's
# own permission needs evolve.
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.39"

  create_role = true
  role_name   = "${var.cluster_name}-ebs-csi-driver"

  trusted_role_services = ["pods.eks.amazonaws.com"]
  role_requires_mfa     = false

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = module.ebs_csi_pod_identity.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicyV2"
}

resource "aws_eks_pod_identity_association" "ebs_csi_driver" {
  cluster_name = module.eks.cluster_name
  # Service account name confirmed via:
  #   aws eks describe-addon-configuration --addon-name aws-ebs-csi-driver \
  #     --addon-version <version> --query podIdentityConfiguration
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = module.ebs_csi_pod_identity.iam_role_arn

  tags = var.tags
}
