# Public hosted zone for var.domain_name. Provisioned out-of-band (not by
# this stack) — looked up by name rather than created here, so `terraform
# apply` never risks standing up a second zone with different NS records
# and silently breaking delegation. If this data source 404s, the zone
# needs to be created (and delegated from the registrar/parent zone for
# chaima.online) before anything below can work.
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# Pod Identity association giving the external-dns EKS addon
# (cluster_addons.external-dns in main.tf) write access to this zone.
# Service account name ("external-dns") confirmed via:
#   aws eks describe-addon-configuration --addon-name external-dns \
#     --addon-version <version> --query podIdentityConfiguration
# which also lists AmazonRoute53FullAccess as the "recommended" policy;
# scoped down here to just this zone instead, matching the rest of this
# stack's least-privilege IRSA/pod-identity roles.
#
# Role/trust-policy creation via terraform-aws-modules/iam/aws (matching
# docs/DECISIONS.md #1 — community modules, not hand-rolled resources),
# same v5.x line as iam.tf's IRSA modules. `iam-assumable-role`, not
# `iam-role-for-service-accounts-eks`: that one is OIDC/IRSA-specific
# (federated trust to the cluster's OIDC provider); Pod Identity's trust
# principal is the `pods.eks.amazonaws.com` *service*, which
# `trusted_role_services` covers directly, and `trusted_role_actions`
# already defaults to exactly `["sts:AssumeRole", "sts:TagSession"]` —
# no override needed. The module only creates the role + trust policy;
# the actual permissions stay as plain `aws_iam_role_policy` resources
# below so each one's scope is explicit and reviewable in the diff,
# rather than hidden behind an `attach_*_policy` flag.
module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.39"

  create_role = true
  role_name   = "${var.cluster_name}-external-dns"

  trusted_role_services = ["pods.eks.amazonaws.com"]

  tags = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  name = "route53-access"
  role = module.external_dns_pod_identity.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ChangeRecordsInThisZone"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = [data.aws_route53_zone.this.arn]
      },
      {
        # Route53 list/read actions don't support resource-level scoping.
        Sid      = "ListZonesAndRecords"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name = module.eks.cluster_name
  # NOT kube-system — the addon deploys into its own "external-dns"
  # namespace. Got this wrong on the first pass: the association silently
  # never matched, so the pod fell back to the node IAM role (no Route53
  # permissions at all) instead of erroring — confirmed live via
  # `kubectl logs`: "AccessDenied ... assumed-role/<node-group-role> ...
  # not authorized to perform: route53:ListHostedZones", and
  # `kubectl get pod -o jsonpath='{.metadata.namespace}'` showing
  # "external-dns", not "kube-system".
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = module.external_dns_pod_identity.iam_role_arn

  tags = var.tags
}

# Same shape for the cert-manager EKS addon (cluster_addons.cert-manager in
# main.tf), whose Route53 DNS-01 solver needs write access to this zone.
# Namespace/service-account name ("cert-manager"/"cert-manager") match the
# upstream chart's defaults, which the addon mirrors.
module "cert_manager_pod_identity" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.39"

  create_role = true
  role_name   = "${var.cluster_name}-cert-manager"

  trusted_role_services = ["pods.eks.amazonaws.com"]

  tags = var.tags
}

resource "aws_iam_role_policy" "cert_manager" {
  name = "route53-dns01-solver"
  role = module.cert_manager_pod_identity.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetChangeStatus"
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
      {
        Sid      = "ChangeRecordsInThisZone"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = [data.aws_route53_zone.this.arn]
      },
      {
        Sid      = "ListZonesForZoneDiscovery"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  cluster_name    = module.eks.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"
  role_arn        = module.cert_manager_pod_identity.iam_role_arn

  tags = var.tags
}

# Pod Identity for the Crossplane AWS family provider
# (charts/env/prod/critical/crossplane) — namespace/service-account match
# that chart's DeploymentRuntimeConfig (templates/deploymentruntimeconfig.yaml).
#
# Scoped to ACM + Route53 — what Crossplane actually manages (the wildcard
# cert for the ALB ingresses, and its DNS validation record). Narrow
# further, or widen, as more Crossplane-managed resource types are added.
module "crossplane_aws_provider_pod_identity" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.39"

  create_role = true
  role_name   = "${var.cluster_name}-crossplane-aws-provider"

  trusted_role_services = ["pods.eks.amazonaws.com"]

  tags = var.tags
}

resource "aws_iam_role_policy" "crossplane_aws_provider" {
  name = "acm-and-route53"
  role = module.crossplane_aws_provider_pod_identity.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ACM doesn't support resource-level scoping for RequestCertificate
        # (no ARN exists yet at request time), and AWS's own ACM IAM
        # examples leave the rest at Resource "*" too — there's no useful
        # narrower scope for a service where certs aren't tied to a
        # specific parent resource.
        Sid    = "ManageCertificates"
        Effect = "Allow"
        Action = [
          "acm:RequestCertificate",
          "acm:DescribeCertificate",
          "acm:GetCertificate",
          "acm:ListCertificates",
          "acm:ListTagsForCertificate",
          "acm:AddTagsToCertificate",
          "acm:RemoveTagsFromCertificate",
          "acm:RenewCertificate",
          "acm:DeleteCertificate",
        ]
        Resource = ["*"]
      },
      {
        # Same shape as the cert-manager and external-dns policies above —
        # write scoped to this one hosted zone.
        Sid      = "ChangeRecordsInThisZone"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = [data.aws_route53_zone.this.arn]
      },
      {
        Sid      = "GetChangeStatus"
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
      {
        Sid      = "ListZonesAndRecords"
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "crossplane_aws_provider" {
  cluster_name    = module.eks.cluster_name
  namespace       = "crossplane-system"
  service_account = "provider-aws"
  role_arn        = module.crossplane_aws_provider_pod_identity.iam_role_arn

  tags = var.tags
}

# The wildcard ACM cert for the ALB-fronted ingresses (argocd, greeter) is
# no longer managed here — moved to Crossplane
# (charts/env/prod/critical/crossplane/templates/certificate*.yaml), which
# now has real ACM+Route53 permissions below instead of the placeholder
# sts:GetCallerIdentity-only policy. See that chart's README for the
# Certificate/Record/CertificateValidation resources and why the
# validation Record needs one manual value filled in after first sync.
