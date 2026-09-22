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

# Scoped to `main` (CD workflows) and `v*` tags (published Releases) only.
# Uses GitHub's newer "immutable subject claims" format (repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:...) rather than
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
    # cd.yml / cd-staging.yml: workflow_run runs in the context of the
    # default branch, so their subject is main even for releases/** builds.
    "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:ref:refs/heads/main",
    # cd-release.yml: a published Release runs with the tag as its ref.
    "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:ref:refs/tags/v*",
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
    sid    = "ECRPushToGreeterAndSignatureReposOnly"
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
    resources = [
      module.ecr_greeter.repository_arn,
      module.ecr_signatures.repository_arn,
    ]
  }
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name        = "${var.cluster_name}-github-actions-ecr-push"
  description = "Push-only access to the greeter ECR repo, for CI/CD via GitHub OIDC"
  policy      = data.aws_iam_policy_document.github_actions_ecr_push.json
  tags        = var.tags
}
