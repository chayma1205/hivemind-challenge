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
#
# `role_requires_mfa = false` on every module call below is required, not
# cosmetic: the module defaults it to `true` (aimed at humans/IAM-user
# role assumption) and, left on, adds an `aws:MultiFactorAuthPresent`
# condition to the *same* trust statement as the `pods.eks.amazonaws.com`
# principal — which would make the role permanently unassumable by Pod
# Identity, since a service-to-service STS call never carries an MFA
# context. Caught in the plan diff before applying, not after breaking
# auth for external-dns/cert-manager/crossplane.
module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.39"

  create_role = true
  role_name   = "${var.cluster_name}-external-dns"

  trusted_role_services = ["pods.eks.amazonaws.com"]
  role_requires_mfa     = false

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
  role_requires_mfa     = false

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
  role_requires_mfa     = false

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

# Per-hostname ACM certs for the ALB-fronted ingresses (argocd, greeter) —
# one each, not a shared wildcard. Back on Terraform, not Crossplane:
# Crossplane's Certificate/Record/CertificateValidation setup
# (charts/env/prod/critical/crossplane/templates/certificate*.yaml, now
# removed) needed a value copied by hand from the Certificate's assigned
# validation record into the Record resource after every first sync — no
# Composition existed to wire that automatically. Confirmed live on a
# fresh cluster rebuild: nobody had done that manual step, so no cert
# ever got created and the ingresses had no HTTPS at all.
#
# Terraform's dependency graph resolves this in one `apply`, no manual
# step, ever: `domain_validation_options` becomes known once the
# certificate is requested, within the same graph the validation record
# and aws_acm_certificate_validation depend on.
#
# No certificate-arn is wired into the ingress charts' values.yaml for
# these — deliberately. The AWS Load Balancer Controller auto-discovers a
# matching cert by comparing an Ingress's spec.tls[].hosts (and
# rules[].host) against ACM
# (https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/cert_discovery/),
# so creating the right cert here is the entire fix — nothing needs to
# reference its ARN anywhere.
locals {
  ingress_hostnames = {
    argocd  = "argocd.${var.domain_name}"
    greeter = "greeter.${var.domain_name}"
  }
}

resource "aws_acm_certificate" "ingress" {
  for_each = local.ingress_hostnames

  domain_name       = each.value
  validation_method = "DNS"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "ingress_cert_validation" {
  for_each = {
    for k, cert in aws_acm_certificate.ingress : k => one(cert.domain_validation_options)
    # domain_validation_options is a set (no index access — Terraform
    # rejects [0] on it, "elements of a set... don't have any separate
    # index"), but single-hostname (non-SAN) certs always have exactly
    # one entry, so one(...) — which requires and unwraps exactly one
    # element — is the correct, safe extraction here, not a workaround.
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "ingress" {
  for_each = aws_acm_certificate.ingress

  certificate_arn         = each.value.arn
  validation_record_fqdns = [aws_route53_record.ingress_cert_validation[each.key].fqdn]
}
