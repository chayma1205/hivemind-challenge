# cert-manager (env/prod/critical)

Wrapper chart that installs [cert-manager](https://cert-manager.io/) into
the `hivemind-prod` EKS cluster, plus an optional `ClusterIssuer` for
Let's Encrypt via Route53 DNS-01 validation.

Lives under `charts/env/prod/critical/` for the same reason as
[`../karpenter`](../karpenter) and
[`../aws-load-balancer-controller`](../aws-load-balancer-controller):
cluster-scoped, one per cluster, pinned to the system node group.

## Prerequisite

The controller needs an **IRSA role** with Route53 permissions
(`route53:ChangeResourceRecordSets`/`ListResourceRecordSets` on hosted
zones, plus `GetChange`/`ListHostedZonesByName`) to complete DNS-01
challenges. Provisioned in `terraform/envs/prod` by
`module.cert_manager_irsa`
(`terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`,
`attach_cert_manager_policy = true`) and wired into
`serviceAccount.annotations."eks.amazonaws.com/role-arn"` in
[`values.yaml`](values.yaml) from that module's `iam_role_arn` output.

## ⚠️ Hosted zone scope not narrowed

`cert_manager_hosted_zone_arns` is left at the Terraform module's default
(`arn:aws:route53:::hostedzone/*` — every hosted zone in the account)
because no Route53 hosted zone exists yet for this project (no real domain
is set up — see the `TODO`s throughout the other charts' `values.yaml`).
Once one exists, narrow `module.cert_manager_irsa`'s
`cert_manager_hosted_zone_arns` in `terraform/envs/prod/main.tf` to that
zone's specific ARN.

## The `ClusterIssuer` is disabled by default

`clusterIssuer.enabled: false` — a DNS-01 issuer needs a real domain to
create validation records against, which doesn't exist yet. Once it does,
set `clusterIssuer.enabled: true` and `clusterIssuer.email` to a real
contact address (used only for Let's Encrypt expiry/abuse notices).

No AWS credentials need to be set on the `ClusterIssuer` itself — the
Route53 DNS-01 solver runs as the controller pod and picks up its IRSA
role automatically (the AWS SDK's default credential chain), the same way
`kubectl exec`ing into the controller pod would.

## Install

```bash
cd charts/env/prod/critical/cert-manager
helm dependency update

helm upgrade --install cert-manager . \
  --namespace cert-manager --create-namespace \
  -f values.yaml
```

## Notes

* `crds.enabled: true` renders CRDs as regular templates instead of
  Helm's special `crds/` directory — `helm template` (and so Argo CD)
  never applies content from that directory, so without this the CRDs
  would silently never get installed via GitOps.
* `replicaCount: 2` on the controller/webhook/cainjector for HA, unlike
  the chart's own default of 1.
