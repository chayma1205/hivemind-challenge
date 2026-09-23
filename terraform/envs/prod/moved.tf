# State moves for domain.tf's Pod Identity roles switching from
# hand-rolled `aws_iam_role` to `terraform-aws-modules/iam/aws`
# (same commit as this file's own addition). Without these, Terraform
# tries to destroy-then-create each role under an *identical* name
# (module role_name matches the old hardcoded name exactly, deliberately
# — no rename intended, just a different resource that creates it) — hit
# live: AWS refuses the delete first ("Cannot delete entity, must delete
# policies first" — the inline aws_iam_role_policy didn't move with it,
# since the plan saw its `role` argument as unchanged, same literal
# string either way), then refuses the create too ("EntityAlreadyExists"
# — the old role is still there, delete having failed). A `moved` block
# tells Terraform these are the same real AWS role under a new address —
# an in-place state move, no destroy/create, no conflict.
moved {
  from = aws_iam_role.external_dns
  to   = module.external_dns_pod_identity.aws_iam_role.this[0]
}

moved {
  from = aws_iam_role.cert_manager
  to   = module.cert_manager_pod_identity.aws_iam_role.this[0]
}

moved {
  from = aws_iam_role.crossplane_aws_provider
  to   = module.crossplane_aws_provider_pod_identity.aws_iam_role.this[0]
}
