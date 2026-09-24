# SNS topic Alertmanager publishes to
# (charts/env/prod/central-services/kube-prometheus-stack's
# alertmanager.config.receivers "sns" entry) and an email subscription on
# it — this is the actual alert delivery path, chosen over SES/SMTP
# specifically to avoid a static credential: Alertmanager's `sns_configs`
# receiver signs requests with AWS SigV4 and, left blank, falls back to
# the AWS SDK's default credential chain — which for a pod means its Pod
# Identity association below, no access key anywhere. SES's SMTP
# interface has no equivalent: its SMTP password is derived from a
# long-lived IAM access key, which is exactly the kind of static
# credential this stack's IAM has avoided everywhere else (see
# docs/DECISIONS.md's "OIDC everywhere, no static credentials" thread).
resource "aws_sns_topic" "alertmanager" {
  name = "${var.cluster_name}-alertmanager"
  tags = var.tags
}

# Confirmation is a real, one-time manual step: SNS emails
# var.alert_email a confirmation link on first apply, and delivers
# nothing to it until that link is clicked — the same class of
# human-in-the-loop step as this stack's other credential/identity setup
# (docs/DECISIONS.md #10). `terraform apply` succeeds regardless of
# whether it's been clicked yet; only delivery is gated on it.
resource "aws_sns_topic_subscription" "alertmanager_email" {
  topic_arn = aws_sns_topic.alertmanager.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Same iam-assumable-role / role_requires_mfa=false pattern as
# domain.tf's Pod Identity roles (see that file's comment on
# module "external_dns_pod_identity" for why role_requires_mfa must be
# false). Kept here rather than domain.tf since this has nothing to do
# with the hosted zone/DNS.
module "alertmanager_pod_identity" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.39"

  create_role = true
  role_name   = "${var.cluster_name}-alertmanager"

  trusted_role_services = ["pods.eks.amazonaws.com"]
  role_requires_mfa     = false

  tags = var.tags
}

resource "aws_iam_role_policy" "alertmanager_sns" {
  name = "sns-publish"
  role = module.alertmanager_pod_identity.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishToAlertTopic"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alertmanager.arn]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "alertmanager" {
  cluster_name = module.eks.cluster_name
  # Must match
  # charts/env/prod/central-services/kube-prometheus-stack/values.yaml's
  # kube-prometheus-stack.alertmanager.serviceAccount.name — pinned there
  # (rather than left at the subchart's auto-generated default) for
  # exactly this: a stable target for this association.
  namespace       = "monitoring"
  service_account = "alertmanager"
  role_arn        = module.alertmanager_pod_identity.iam_role_arn

  tags = var.tags
}
