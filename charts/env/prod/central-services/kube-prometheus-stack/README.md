# kube-prometheus-stack (env/prod/central-services)

Wrapper chart that installs [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
— Prometheus, Alertmanager, Grafana, the Prometheus Operator, node-exporter,
and kube-state-metrics — into the `hivemind-prod` EKS cluster.

Lives under `charts/env/prod/central-services/` for the same reason as
[`../argocd`](../argocd): a shared service the rest of the cluster and its
operators use, not cluster-bootstrap infrastructure like
[`../../critical/karpenter`](../../critical/karpenter) — nothing else has
to be running first for this to come up, and nothing else depends on it
being up to function.

**Status: not yet deployed.** This chart exists to be reviewed. It isn't
referenced by `charts/env/prod/argocd-apps.yaml` yet — regenerating that
(`scripts/generate-argocd-apps.sh`) and pushing is what actually deploys
it.

## What this closes

`docs/ASSESSMENT.md`'s longest-standing gap: no observability beyond raw
`metrics-server` / EKS's CloudWatch defaults, and specifically the live
incident it names as evidence — a Karpenter node whose kubelet stopped
posting status for hours, unnoticed by anything automated. See
[`templates/prometheusrule-node-health.yaml`](templates/prometheusrule-node-health.yaml)'s
`NodeNotReadyTooLong` alert for the direct fix, and the subchart's own
large set of default rules (`KubePodCrashLooping`, HPA/PDB/quota alerts,
...) for everything else this closes for free just by existing.

This chart's Alertmanager has a second consumer besides Prometheus:
[`../argocd`](../argocd)'s notifications controller pushes into it
directly (see that chart's README, "Notifications") to alert on
Application `OutOfSync`/`Degraded` transitions — reusing this chart's
SNS email delivery rather than standing up a separate path.

## Prerequisite: the EBS CSI driver

Prometheus/Alertmanager/Grafana all use PersistentVolumeClaims
(`templates/storageclass-gp3.yaml`'s `gp3` StorageClass), which needs the
`aws-ebs-csi-driver` EKS addon — nothing in this cluster needed persistent
storage before this chart, so it didn't exist yet.
`terraform/envs/prod/main.tf` now provisions it (addon +
`aws_eks_pod_identity_association`, same pattern as every other addon in
that file). **Apply that Terraform change before syncing this chart** —
the PVCs will sit `Pending` (no matching StorageClass provisioner)
without it.

## Design decisions worth knowing before changing this

* **Not pinned to the system node group.** Every other chart in
  `charts/env/prod/critical/` pins itself to `role: system` because it's
  bootstrap-order-sensitive (Karpenter has to run before it can provision
  capacity for anything else). This stack has no such circularity, and
  the system node group is already tight on CPU (86%/67% *requests* on
  the two nodes, confirmed live before writing this) — adding a
  multi-component monitoring stack on top would have been a
  self-inflicted resource-pressure problem. Karpenter provisions and
  sizes capacity for it instead, same as any other workload; its
  NodePool's `limits.cpu: "100"` (`../../critical/karpenter/values.yaml`)
  has far more headroom than the system group does.
* **node-exporter is the one exception** — it's a DaemonSet and has to
  run on every node, including the two tainted system-group ones (or
  those two nodes, already the most resource-constrained, would be the
  ones with zero node-level metrics). It tolerates
  `CriticalAddonsOnly` broadly rather than needing a `nodeSelector`, so
  it lands everywhere without needing to be scheduled onto the system
  group specifically.
* **No new security group rule needed for scraping.** Checked live
  (`aws ec2 describe-security-group-rules` against the node security
  group) before assuming: the existing "node to node ingress on
  ephemeral ports" rule already covers `1025-65535`, which includes every
  port this stack uses (Prometheus 9090, Alertmanager 9093, Grafana 3000,
  node-exporter 9100, kube-state-metrics 8080). This is exactly the class
  of gap that bit `metrics-server` (a missing SG rule on port 10251,
  `docs/ASSESSMENT.md` bug 2) — checked instead of assumed, this time.
* **`kubeControllerManager`/`kubeScheduler`/`kubeEtcd`/`kubeProxy`
  monitoring is disabled.** EKS doesn't expose these control-plane
  components the way the chart's defaults expect; left enabled, every
  target would sit permanently `down` and generate noise instead of
  signal.
* **Alertmanager delivers via SNS, not SES/SMTP.** Both were considered;
  SNS won specifically to avoid a static credential. Alertmanager's
  built-in email receiver is SMTP-only, and SES's SMTP password is
  derived from a long-lived IAM access key — a real, permanent exception
  to this stack's "no static credentials, ever" pattern
  (`docs/DECISIONS.md`). SNS's `sns_configs` receiver signs requests with
  AWS SigV4 and, with no `access_key`/`secret_key` set, falls back to the
  AWS SDK's default credential chain — which for this pod means its EKS
  Pod Identity association (`terraform/envs/prod/observability.tf`,
  scoped to `sns:Publish` on exactly one topic). The topic has an email
  subscription to the operator's address — SNS emails a confirmation
  link on first apply, and delivers nothing until it's clicked, the same
  class of human-in-the-loop step as this stack's other credential/
  identity setup (`docs/DECISIONS.md` #10). See "Adding another alert
  receiver" below for adding Slack/PagerDuty/etc. alongside SNS.
* **Grafana is ALB-fronted at `grafana.hivemind.chaima.online`**, same
  pattern as `../argocd`/`../../apps/greeter`: no `certificate-arn`
  annotation (the ALB controller auto-discovers a matching ACM cert by
  hostname), and no `tls[].secretName` (the controller doesn't do
  secret-based TLS termination, so there's nothing for one to do). The
  cert itself is Crossplane-managed —
  `grafana` was added to
  `../../critical/crossplane/values.yaml`'s `ingressCertificates.hostnames`
  alongside `argocd`/`greeter`, so it's provisioned the same automatic
  way theirs are
  (`../../critical/crossplane/templates/composition-ingresscertificate.yaml`).
* **`serviceMonitorSelectorNilUsesHelmValues`/`podMonitorSelectorNilUsesHelmValues`/`ruleSelectorNilUsesHelmValues`
  are all `false`** — Prometheus watches every ServiceMonitor/PodMonitor/
  PrometheusRule in the cluster, not just label-matched ones. This is a
  single-tenant cluster; the usual multi-tenant isolation these selectors
  exist for has no real benefit here, only the cost of remembering to
  label every future monitor correctly.

## Adding another alert receiver

To add Slack/PagerDuty/etc. *alongside* SNS: add a new entry under
`kube-prometheus-stack.alertmanager.config.receivers` in `values.yaml`,
and route to it either as the default (`route.receiver`) or via a
sub-route matching on severity/alertname. For anything needing a
credential (a Slack webhook URL, a PagerDuty integration key), reference
a Kubernetes Secret via `alertmanagerSpec.secrets` rather than putting
the credential in this file. Don't remove the `"null"` receiver when
editing this — the subchart injects its own route sending the
always-firing `Watchdog` alert to a receiver literally named `"null"`,
and removing that receiver definition leaves the route pointing at
nothing (confirmed by rendering this chart and reading the generated
config — this isn't a guess).

## Install (once reviewed — not yet wired into `argocd-apps.yaml`)

```bash
# 1. Apply the prerequisites (terraform/envs/prod): the EBS CSI driver
#    (for this chart's PVCs) and the SNS topic + Pod Identity role for
#    Alertmanager (observability.tf). Confirm the SNS subscription
#    confirmation email (sent to var.alert_email) is clicked, or alerts
#    will fire but never arrive.
cd terraform/envs/prod && terraform apply \
  -target=module.eks \
  -target=module.ebs_csi_pod_identity -target=aws_iam_role_policy_attachment.ebs_csi_driver -target=aws_eks_pod_identity_association.ebs_csi_driver \
  -target=aws_sns_topic.alertmanager -target=aws_sns_topic_subscription.alertmanager_email -target=module.alertmanager_pod_identity -target=aws_iam_role_policy.alertmanager_sns -target=aws_eks_pod_identity_association.alertmanager

# 2. Regenerate and commit the Argo CD Application set
cd ../../.. && ./scripts/generate-argocd-apps.sh

# 3. Let Argo CD pick it up (push to main), or install directly to check it first:
cd charts/env/prod/central-services/kube-prometheus-stack
helm dependency update
helm upgrade --install kube-prometheus-stack . \
  --namespace monitoring --create-namespace \
  -f values.yaml
```

## Notes

* `replicas: 1` on Prometheus/Alertmanager/Grafana, not the `2` this
  repo's other central-services/critical charts default to for HA — a
  deliberate cost/complexity tradeoff for a first pass at this stack
  specifically (Prometheus HA in particular needs either external storage
  or accepting duplicate/inconsistent data between replicas, which is its
  own decision this chart isn't making yet). Revisit once this is
  actually load-bearing.
* Storage sizes (20Gi Prometheus, 2Gi Alertmanager, 2Gi Grafana) are
  sized with headroom for this cluster's current scale, not tuned tight —
  `allowVolumeExpansion: true` on the `gp3` StorageClass makes growing
  any of them later a live, non-disruptive resize.
