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
resource "aws_iam_role" "external_dns" {
  name = "${var.cluster_name}-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  name = "route53-access"
  role = aws_iam_role.external_dns.id

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
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn

  tags = var.tags
}

# Same shape for the cert-manager EKS addon (cluster_addons.cert-manager in
# main.tf), whose Route53 DNS-01 solver needs write access to this zone.
# Namespace/service-account name ("cert-manager"/"cert-manager") match the
# upstream chart's defaults, which the addon mirrors.
resource "aws_iam_role" "cert_manager" {
  name = "${var.cluster_name}-cert-manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cert_manager" {
  name = "route53-dns01-solver"
  role = aws_iam_role.cert_manager.id

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
  role_arn        = aws_iam_role.cert_manager.arn

  tags = var.tags
}

# Pod Identity for the Crossplane AWS family provider
# (charts/env/prod/critical/crossplane) — namespace/service-account match
# that chart's DeploymentRuntimeConfig (templates/deploymentruntimeconfig.yaml).
#
# Minimal placeholder policy (sts:GetCallerIdentity only) by design — see
# that chart's README: attach real permissions once specific AWS resources
# Crossplane should manage are decided, rather than guessing a scope here.
resource "aws_iam_role" "crossplane_aws_provider" {
  name = "${var.cluster_name}-crossplane-aws-provider"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "crossplane_aws_provider" {
  name = "placeholder-sts-only"
  role = aws_iam_role.crossplane_aws_provider.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ProveCredentialChainWorks"
      Effect   = "Allow"
      Action   = ["sts:GetCallerIdentity"]
      Resource = ["*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "crossplane_aws_provider" {
  cluster_name    = module.eks.cluster_name
  namespace       = "crossplane-system"
  service_account = "provider-aws"
  role_arn        = aws_iam_role.crossplane_aws_provider.arn

  tags = var.tags
}

# Wildcard ACM cert for the ALB-fronted ingresses (argocd, greeter — see
# their charts' values.yaml). DNS-validated against the zone above rather
# than cert-manager: the AWS Load Balancer Controller terminates TLS using
# an ACM certificate ARN (`alb.ingress.kubernetes.io/certificate-arn`), not
# a cert-manager-issued Secret, so ACM is the native fit here regardless of
# cert-manager's own DNS-01 setup above (which stays useful for anything
# that needs an in-cluster TLS secret instead of ALB-terminated TLS).
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  subject_alternative_names = [var.domain_name]

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "wildcard_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.wildcard_cert_validation : r.fqdn]
}
