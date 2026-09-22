# Project assessment

An honest evaluation of this repo's current state: engineering level it
represents, what's genuinely strong, and the concrete gaps — security,
automation, and otherwise — that stand between this and a real production
system. Written 2026-09-22, after the initial EKS/GitOps stack went live.

## Seniority level: **Senior**, with a few mid-level gaps that would come up in review

This isn't a junior or mid-level submission. The signals that put it at
senior level:

* **OIDC everywhere, no static credentials, ever** — GitHub Actions → AWS
  via OIDC federation scoped to `ref:refs/heads/main` and `ref:refs/tags/v*`
  only (not `pull_request`), using the newer "immutable subject claim"
  format deliberately because the older name-based format silently
  doesn't match for repos created after 2026-07-15 (docs/DECISIONS.md
  documents this was caught via a real failed `AssumeRoleWithWebIdentity`
  call, not assumed).
* **Consistent least-privilege IAM** — every role is scoped to exactly the
  actions/resources it needs: ECR push scoped to two specific repository
  ARNs, Route53 writes scoped to one hosted zone ARN, cert-manager/
  external-dns/crossplane each get their own narrowly-scoped role rather
  than sharing one. Read and write git credentials for the *same* repo are
  deliberately split (repo-server: read-only deploy key; Image Updater: a
  separate write-scoped one) so a compromised sync path can't push.
* **Supply-chain security most senior engineers don't bother with**:
  keyless cosign signing (OIDC identity, Rekor transparency log, no
  signing key to manage), SBOM generation, and SLSA v1 provenance
  attestations, all in the CI pipeline — with a dedicated MUTABLE ECR repo
  for the signatures because cosign rewrites `.sig`/`.att` tags in place,
  which the app image repo's IMMUTABLE tag policy would reject. That's a
  subtle interaction most people miss entirely.
* **A real decision log** (`docs/DECISIONS.md`) — not just what was
  decided but the context, the tradeoff, and — notably — decisions
  *revisited* with dated addenda when circumstances changed (public→private
  repo, single-repo→split-repo CI/CD) rather than silently rewritten. This
  is the single strongest signal of seniority in the repo: it shows
  reasoning under changing constraints, not just a snapshot.
* **Correct, non-obvious infrastructure choices**: S3 native locking
  (`use_lockfile`) instead of a DynamoDB table now that Terraform ≥1.11
  supports it; EKS Pod Identity over IRSA for newer AWS-native EKS
  addons (which often don't expose a serviceAccount-annotation surface for
  IRSA at all — confirmed live, not assumed, via
  `aws eks describe-addon-configuration`); GitOps app-of-apps that's
  self-managing (the root `Application` watches its own generator output,
  so a re-generated `argocd-apps.yaml` needs no manual re-apply).

**What would read as a gap in a senior-level review** (see below for the
full list): no automated tests beyond a trivial `go test`, no
policy-as-code / static analysis on the Terraform or Kubernetes
manifests, no Pod-level security hardening, no branch protection, no
observability beyond raw metrics-server, and several real bugs that only
surfaced under live testing rather than being caught earlier (see
"Bugs found only by running the thing," below) — normal for a fast-moving
solo build, but each one is the kind of thing a second reviewer or a CI
policy gate would have caught before it reached a running cluster.

## Bugs found only by running the thing

Notable because none of these were visible from reading the code — every
one needed the actual cluster to expose it. Worth calling out because it's
a pattern: several components were configured based on reasonable
assumptions about default namespaces/ports that turned out to be wrong,
and nothing in the pipeline would have caught it before a live sync.

1. **external-dns Pod Identity wired to the wrong namespace.** Assumed the
   EKS addon deploys into `kube-system`; it actually uses its own
   `external-dns` namespace. The Pod Identity association silently never
   matched — no error, no crash — the pod just fell back to the EC2 node
   group's IAM role (zero Route53 permissions) and retried
   `route53:ListHostedZones` with `AccessDenied` every 60 seconds for the
   life of the pod. No DNS records were ever created. This is the kind of
   bug that's invisible in a `terraform plan`/`helm template` review and
   only shows up as "why isn't the ingress hostname resolving" days later.
2. **metrics-server unreachable cluster-wide** — the EKS module's default
   node security group rules cover the control plane's usual webhook
   ports (443/4443/6443/8443/9443) and kubelet (10250), but not
   metrics-server's own aggregated-API port (10251). Every HPA in the
   cluster silently reported `<unknown>` targets, which cascaded into Argo
   CD marking *any* Application with an HPA as `Degraded` — a
   security-group gap manifesting as an apparently unrelated GitOps health
   problem two layers away.
3. **Crossplane's own CRD templates raced its own bootstrap** — applying a
   `DeploymentRuntimeConfig` in the same Argo CD sync wave as the
   Deployment that registers its CRD. Argo CD validates every resource's
   GVK is discoverable *before* wave-sequencing starts, so this didn't
   just delay — it failed the entire sync batch, every time, for every
   retry. `sync-wave` annotations alone didn't fix it; needed
   `SkipDryRunOnMissingResource=true`.
4. **The split-repo migration left ECR with nothing in it.** After
   `hivemind-greeter` was split out, its CI run was manually cancelled and
   never re-run, so the ECR repo — freshly created by this same
   apply — had zero images. The chart's bootstrap image tag (`ea792b8`)
   was a stale reference to a commit that doesn't exist in the new repo's
   history at all. `ImagePullBackOff` until someone (this session, by
   hand, since the CI pipeline that should own this never ran) built and
   pushed an image directly.

None of these are exotic. All four are the class of bug that a `terraform
plan` in CI, a `helm template | kubeval`, or literally anyone clicking
through the running cluster once would have caught before it shipped.
That absence — not the bugs themselves — is the real gap.

## Gaps

### Security

* **No Pod-level hardening.** No `securityContext` on the greeter
  Deployment (or most charts) — no `runAsNonRoot`, no
  `readOnlyRootFilesystem`, no `allowPrivilegeEscalation: false`, no
  capability drops. The Dockerfile does the right thing at the image
  layer (distroless base, `USER nonroot:nonroot`), but there's no
  defense-in-depth at the Pod spec layer, and nothing (no Pod Security
  Admission label, no OPA/Kyverno policy) would stop a future chart from
  regressing that.
* **No NetworkPolicy anywhere in the cluster.** Every pod can reach every
  other pod by default. For a cluster running cert-manager, Crossplane
  (with real AWS credentials via Pod Identity), and the ALB controller,
  that's a meaningfully flat blast radius if any one workload is
  compromised.
* **Secrets are raw Kubernetes Secrets, no encryption-at-rest story
  beyond EKS's default EBS/etcd encryption.** No External Secrets
  Operator, no AWS Secrets Manager/Parameter Store integration, no
  Sealed Secrets. The two git deploy-key Secrets and any future
  application secrets are one `kubectl get secret -o yaml` away from
  plaintext for anyone with cluster read access.
* **No policy-as-code on the Terraform.** No `tfsec`, `checkov`, or OPA/
  Conftest gate in CI — nothing would flag a future security-group rule
  that's too broad, an S3 bucket without encryption, or an IAM policy
  drifting toward `*` before it merges.
* **Branch protection couldn't be verified** (GitHub API 403s on a free
  private repo), but from the commit history every change on `main` —
  including this session's — went straight to `main` with no PR, no
  required review, no status-check gate. Fine for a solo build; a real
  security gap the moment more than one person has push access.
* **No CODEOWNERS, no SECURITY.md, no dependency-update automation**
  (no Dependabot/Renovate config found) — Go module and Helm chart
  versions are all hand-pinned with no mechanism to know when a pinned
  version has a disclosed CVE.
* **The EKS public endpoint's allowed CIDR is a single hardcoded IP**
  captured once, with a code comment already flagging it as something
  that goes stale. Correct instinct (restrict public access at all,
  rather than leaving 0.0.0.0/0), but a static single-IP allowlist is
  itself an operational trap the moment anyone's network changes —
  worth a VPN/bastion or a maintained IP set instead.

### Automation / reliability

* **No CI validation of the Terraform at all** — no `terraform plan`,
  no `terraform validate`, no drift-detection job. `ci.yml` in this repo
  only lints the Helm chart and checks `argocd-apps.yaml` freshness; the
  Terraform side has zero automated gate before `apply`.
* **No integration or infra tests.** The Go app has a trivial `go test`;
  there's no Terratest (or equivalent) exercising the Terraform modules,
  no `helm template` + `kubeconform`/`kubeval` schema validation in CI,
  and — as the four live-only bugs above show — nothing that would catch
  a wrong namespace, a missing security-group rule, or a bootstrap race
  before it reaches a real cluster.
* **No staging environment that actually exists.** `cd-staging.yml` in
  `hivemind-greeter` builds and pushes staging-tagged images, but there's
  no staging Kubernetes namespace, Argo CD Application, or cluster for
  those images to ever land on — the pipeline half exists.
* **No observability beyond raw `metrics-server` / EKS's CloudWatch
  defaults** — explicitly called out as a known gap in
  `docs/ARCHITECTURE.md`. No log aggregation, no alerting, no dashboards,
  no SLOs. If a Pod crash-loops at 3am, nothing pages anyone.
* **No documented disaster-recovery procedure.** State lives in S3
  (versioned, good) and git, so the *ingredients* to rebuild exist, but
  there's no tested runbook for "the cluster is gone, rebuild it" — and
  the four bugs above suggest a from-scratch rebuild wouldn't go cleanly
  without hitting all of them again in sequence.
* **Several genuinely manual, recurring operational steps by design**
  (documented, deliberate, not accidental): GitHub deploy-key
  registration and the two K8s Secret creations are explicitly
  human-in-the-loop (`docs/DECISIONS.md` #10's stated rationale: an
  agent — or a pipeline — writing credentials into a cluster shouldn't be
  fully automated). Reasonable for a single-operator setup; doesn't scale
  to a team without a proper credential-provisioning mechanism.
* **The ACM certificate validation flow has no automation linking
  Certificate → DNS record → CertificateValidation** — currently a
  manual "read the assigned value, paste it, re-apply" step per
  certificate, discussed separately as its own follow-up.

### Documentation / process

* **No root `README.md` or `LICENSE`.** `docs/` has strong internal docs
  (ARCHITECTURE, DECISIONS, RUNBOOK), but there's no entry point for
  someone landing on the repo cold, and no license means the legal
  terms of reuse are undefined.
* **RUNBOOK.md and ARCHITECTURE.md have drifted from reality in
  places** during this session's rapid changes (e.g. references to a
  build/push flow that moved to a different repo) — worth a pass to
  reconcile now that the dust has settled, the same way `DECISIONS.md`
  was kept current throughout.

## Net assessment

The *decisions* in this repo are consistently senior — OIDC-only auth,
least-privilege IAM, real supply-chain security, a maintained decision
log, correct-but-non-obvious infra choices. The *verification* layer
around those decisions is the weakest part: nothing short of an actual
live cluster catches a wrong namespace or a missing security-group rule,
and this repo had no automated gate that would have caught any of the
four bugs above before they shipped. That combination — strong judgment,
thin verification — reads less like a skills gap and more like a
time/scope tradeoff under a challenge deadline. Closing it is mostly
CI/policy investment (`terraform plan` in CI, `tfsec`/`checkov`,
`helm template` schema validation, Pod Security Admission), not new
architecture.
