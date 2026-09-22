# argocd-image-updater (env/prod/central-services)

Wrapper chart that installs [Argo CD Image Updater](https://argocd-image-updater.readthedocs.io/),
which watches ECR for new `hivemind-greeter` image tags and can update the
`greeter` Application's `image.tag` parameter automatically — replacing the
manual "build, push, hand-edit `argocd-params.env`, commit" loop documented
in [RUNBOOK.md](../../../../docs/RUNBOOK.md).

Lives under `charts/env/prod/central-services/` alongside
[`../argocd`](../argocd) — like Argo CD itself, it's a control-plane
component installed once per cluster, not scoped to one app or environment.

## Prerequisites

* An **IRSA role** with ECR read access
  (`AmazonEC2ContainerRegistryReadOnly`) to check tags and pull manifests.
  Provisioned in `terraform/envs/prod` by `module.argocd_image_updater_irsa`,
  wired into `serviceAccount.annotations."eks.amazonaws.com/role-arn"` in
  [`values.yaml`](values.yaml) from that module's `iam_role_arn` output.
* A **git write credential** for [`templates/imageupdater.yaml`](templates/imageupdater.yaml)'s
  write-back: an SSH deploy key with **write** access to this repo
  (different from — and in addition to — the read-only key Argo CD's
  repo-server uses to clone/sync; see
  [`../argocd/README.md`](../argocd/README.md#repository-access-private-repo)),
  stored as a `Secret` named `argocd-image-updater-git-creds` in the
  `argocd` namespace:
  ```bash
  kubectl -n argocd create secret generic argocd-image-updater-git-creds \
    --from-literal=sshPrivateKey="$(cat /path/to/write_key)"
  ```
  Same one-time manual bootstrap step as the repo-server credential, and
  for the same reason (see docs/DECISIONS.md #10) — not something this
  chart or an automated pipeline creates for you.

## How ECR authentication actually works here

ECR isn't in Image Updater's list of natively-understood registries (unlike
Docker Hub, GCR, Quay, ACR) — there's no "just set `credentials: irsa`" mode.
The [documented pattern](https://argocd-image-updater.readthedocs.io/en/stable/configuration/registries/)
is an external script (`credentials: ext:/scripts/ecr-login.sh`) that
outputs `<username>:<password>` on demand, re-run whenever the cached
credential expires (`credsexpire`). For ECR that script has to actually run
`aws ecr get-login-password` — which needs the `aws` CLI, and the chart's
default image (`quay.io/argoprojlabs/argocd-image-updater`, Alpine-based)
doesn't include one.

Rather than maintain a custom image just to add a CLI binary, this chart's
`values.yaml` adds an `initContainer` (`public.ecr.aws/aws-cli/aws-cli`)
that copies a real `aws` binary and its supporting files into a shared
`emptyDir`, mounted into the main container at the same paths
(`/usr/local/aws-cli`, `/usr/local/bin/aws`) so `ecr-login.sh` can call it
directly. Verified against the actual image layout (the `aws` binary is a
symlink into `/usr/local/aws-cli/v2/current/...`, which is why both paths
need copying, not just the binary). This is a one-time cost at pod start,
not a periodic job — `aws` stays put for the container's lifetime.

## Install

```bash
cd charts/env/prod/central-services/argocd-image-updater
helm dependency update

helm upgrade --install argocd-image-updater . \
  --namespace argocd \
  -f values.yaml
```

## Notes

* Runs in "kube" mode (`createClusterRoles: true`) — it reads and patches
  Argo CD `Application` CRDs directly via the Kubernetes API, so there's no
  Argo CD server address/credential to configure separately; it uses
  whatever RBAC this chart grants it in-cluster.
* Once running and finding new ECR tags, it still needs write-back
  configured on the `greeter` Application (an `argocd-image-updater.argoproj.io/image-list`
  annotation, etc.) to actually act — that wiring isn't done by this chart
  and is a reasonable next step once this is confirmed healthy.
