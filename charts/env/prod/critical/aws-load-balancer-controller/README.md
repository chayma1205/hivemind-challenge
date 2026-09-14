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

## ⚠️ Prerequisite not yet provisioned

The controller needs an **IRSA role** (IAM role assumed via its Kubernetes
service account) with the AWS-managed `AWSLoadBalancerControllerIAMPolicy`
attached, so it can create/manage ALBs, target groups, security groups,
etc. This isn't yet in `terraform/envs/prod` — typically provisioned via
`terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`
with `attach_load_balancer_controller_policy = true`.

Once that role exists, set
`aws-load-balancer-controller.serviceAccount.annotations."eks.amazonaws.com/role-arn"`
in [`values.yaml`](values.yaml). Until then, `helm install` succeeds but
the controller pod will fail to reconcile any Ingress/Service (missing AWS
permissions).

## Install

```bash
cd charts/env/prod/critical/aws-load-balancer-controller
helm dependency update

helm upgrade --install aws-load-balancer-controller . \
  --namespace kube-system \
  -f values.yaml
```

## Notes

* `vpcId` is left blank by default — the controller falls back to
  instance-metadata discovery, which works fine on EKS-managed nodes. Set
  it explicitly (`terraform output vpc_id`) if that lookup ever proves
  unreliable.
* `ingressClass: alb` / `createIngressClassResource: true` — Ingress
  resources must set `ingressClassName: alb` to be picked up by this
  controller.
