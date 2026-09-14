# aws-load-balancer-controller (env/prod/critical)

Wrapper chart that installs the
[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
into the `hivemind-prod` EKS cluster. It watches `Ingress` (ALB) and
`Service type=LoadBalancer` (NLB) resources and provisions the matching AWS
load balancers — required for both the greeter app's ingress and, once
enabled, Argo CD's own ingress (see
[`charts/env/prod/central-services/argocd`](../../central-services/argocd)).

Lives under `charts/env/prod/critical/` (not `central-services/`) because
its config is tied to this environment's cluster name/region/VPC, same
reasoning as [`../karpenter`](../karpenter).

## Prerequisite

The controller needs an **IRSA role** (IAM role assumed via its Kubernetes
service account) with the AWS-managed `AWSLoadBalancerControllerIAMPolicy`
attached, so it can create/manage ALBs, target groups, security groups,
etc. Provisioned in `terraform/envs/prod` by
`module.aws_load_balancer_controller_irsa`
(`terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`
— the v5.x submodule path, since the current v6.x line needs an AWS
provider version that conflicts with the `eks`/`karpenter` modules) with
`attach_load_balancer_controller_policy = true`, and wired into
`aws-load-balancer-controller.serviceAccount.annotations."eks.amazonaws.com/role-arn"`
in [`values.yaml`](values.yaml) from that module's `iam_role_arn` output.

## Install

```bash
cd charts/env/prod/critical/aws-load-balancer-controller
helm dependency update

helm upgrade --install aws-load-balancer-controller . \
  --namespace kube-system \
  -f values.yaml
```

## Notes

* `vpcId` is set explicitly from `terraform output vpc_id` rather than
  relying on the controller's instance-metadata fallback.
* `ingressClass: alb` / `createIngressClassResource: true` — Ingress
  resources must set `ingressClassName: alb` to be picked up by this
  controller.
