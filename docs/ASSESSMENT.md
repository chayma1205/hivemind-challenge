# Project assessment

An honest evaluation of this repo's current state: engineering level it
represents, what's genuinely strong, and the concrete gaps — security,
automation, and otherwise — that stand between this and a real production
system. Written 2026-09-22, after the initial EKS/GitOps stack went live;
reevaluated later the same day after README/disaster-recovery docs were
added, three of the four originally-found live bugs were fixed and
verified, and a fifth issue was found in the process.

## Scorecard

| Area | Score /10 | Direction since last look |
|---|---|---|
| Architecture & infrastructure design | **9** | — (was already the strongest area) |
| Security posture | **6** | — (no items closed; still the auth story is strong, the workload/network hardening isn't) |
| Automation & CI/CD | **6** | — (supply-chain security still excellent; Terraform CI gate, infra tests, cert automation still absent) |
| Observability & reliability | **4** | ↓ in evidence, not in score — see the still-dead node below |
| Documentation & process | **8** | ↑ from 5 — README, DISASTER_RECOVERY.md, and a full ARCHITECTURE/RUNBOOK reconciliation landed since the first pass |
| Incident response & operational judgment | **8** | new category this pass — see below |

**Overall: 6.8/10 — Senior**, same level as the first assessment, for the
same reason: this isn't an average across uniformly-mid-level work, it's
a spread between consistently senior judgment (architecture, incident
diagnosis) and consistently mid-level *systemic* maturity (nothing
catches these classes of bug or failure *before* a human looks). A
straight numeric average understates the judgment on display and
overstates the operational maturity — read the per-area sections below,
not just the number.

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
one needed the actual cluster to expose it. Worth calling out because
it's a pattern: several components were configured based on reasonable
assumptions about default namespaces/ports that turned out to be wrong,
and nothing in the pipeline would have caught it before a live sync.

1. **external-dns Pod Identity wired to the wrong namespace.** Assumed the
   EKS addon deploys into `kube-system`; it actually uses its own
   `external-dns` namespace. The Pod Identity association silently never
   matched — no error, no crash — the pod just fell back to the EC2 node
   group's IAM role (zero Route53 permissions) and retried
   `route53:ListHostedZones` with `AccessDenied` every 60 seconds for the
   life of the pod. No DNS records were ever created. **Fixed and
   verified**: corrected namespace, restarted the pod, confirmed 8 real
   Route53 records created and an end-to-end HTTPS request resolving.
2. **metrics-server unreachable cluster-wide** — the EKS module's default
   node security group rules cover the control plane's usual webhook
   ports (443/4443/6443/8443/9443) and kubelet (10250), but not
   metrics-server's own aggregated-API port (10251). Every HPA in the
   cluster silently reported `<unknown>` targets, which cascaded into Argo
   CD marking *any* Application with an HPA as `Degraded` — a
   security-group gap manifesting as an apparently unrelated GitOps health
   problem two layers away. **Fixed and verified**: added the missing SG
   rule, confirmed `kubectl top nodes` returns real numbers and the
   `v1beta1.metrics.k8s.io` APIService reports `Available: True`.
3. **Crossplane's own CRD templates raced its own bootstrap** — applying a
   `DeploymentRuntimeConfig` in the same Argo CD sync wave as the
   Deployment that registers its CRD. Argo CD validates every resource's
   GVK is discoverable *before* wave-sequencing starts, so this didn't
   just delay — it failed the entire sync batch, every time, for every
   retry. `sync-wave` annotations alone didn't fix it; needed
   `SkipDryRunOnMissingResource=true`. **Fixed and verified**: Crossplane
   now syncs and reports `Healthy`, all three AWS provider packages
   installed.
4. **The split-repo migration left ECR with nothing in it.** After
   `hivemind-greeter` was split out, its CI run was manually cancelled and
   never re-run, so the ECR repo — freshly created by this same
   apply — had zero images. The chart's bootstrap image tag (`ea792b8`)
   was a stale reference to a commit that doesn't exist in the new repo's
   history at all. `ImagePullBackOff` until someone (this session, by
   hand, since the CI pipeline that should own this never ran) built and
   pushed an image directly. **Fixed**, but by a manual side-channel
   (`buildah`, since no Docker was available), not by the pipeline that's
   supposed to own this — the underlying gap (CI never re-ran after being
   cancelled, and nothing noticed) is unresolved.
5. **A Karpenter-provisioned node went unresponsive and is still down as
   of this reevaluation.** Kubelet stopped posting status entirely
   (`Ready: Unknown` → `NotReady`) roughly three hours before this was
   written; the underlying EC2 instance is still `running` in AWS the
   whole time. Several pods (two Crossplane provider pods, both greeter
   replicas at the time) sat `Terminating` against it until Argo CD's
   `selfHeal` happened to recreate the Deployments elsewhere. **Still
   unresolved** — the fix (`kubectl delete nodeclaim default-x6bhd`, so
   Karpenter properly terminates and replaces it) is identified and
   documented in `docs/RUNBOOK.md`'s troubleshooting section, but node/
   compute-lifecycle changes are gated behind explicit operator approval
   in this environment, and that approval hasn't been given. The node has
   simply been sitting dead, unnoticed by anything automated, for hours.

Four of five are fixed and independently verified, not just patched and
assumed working. The fifth is the more interesting data point for this
reevaluation: it's not a config mistake like the first four, it's a live
demonstration of the observability gap below — nothing alerted, nothing
self-healed at the node level, and it was only found by manually running
`kubectl get nodes` while checking on something else entirely.

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
* **No dependency-update automation** (no Dependabot/Renovate config
  found; see also the Documentation/process section below for
  CODEOWNERS/SECURITY.md) — Go module and Helm chart versions are all
  hand-pinned with no mechanism to know when a pinned version has a
  disclosed CVE.
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
  `docs/ARCHITECTURE.md`, and now with a live example rather than a
  hypothetical: bug 5 above, a node dead for hours with zero automated
  detection. No log aggregation, no alerting, no dashboards, no SLOs, and
  — as of this reevaluation — no node health monitoring either (Karpenter
  has no auto-repair configured/active here). If a Pod crash-loops at
  3am, nothing pages anyone; if a *node* dies at 3am, apparently nothing
  notices at all.
* ~~No documented disaster-recovery procedure~~ **Closed** —
  `docs/DISASTER_RECOVERY.md` now exists, with concrete recovery steps
  for cluster loss, state-bucket loss, hosted-zone loss, bad deploys, and
  credential compromise, plus a validation checklist tied to bugs 1-4
  above so a rebuild doesn't silently reintroduce them. Not yet
  *exercised* end-to-end (nobody's actually run a from-scratch recovery
  drill), so treat it as reviewed-but-untested.
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

* ~~No root `README.md`~~ **Closed** — added, with a repo-layout map,
  what's-running summary, and a condensed bootstrap procedure.
* **Still no `LICENSE`.** The legal terms of reuse remain undefined —
  the one item from the original "no README/LICENSE" pairing that wasn't
  addressed.
* ~~RUNBOOK.md and ARCHITECTURE.md have drifted from reality~~ **Closed**
  — both rewritten to match the current split-repo, private-repo,
  domain/TLS/Crossplane state, including a shared "bugs found by running
  the thing" section kept current in both this doc and `ARCHITECTURE.md`.
* **Still no CODEOWNERS, no SECURITY.md, no dependency-update
  automation** (no Dependabot/Renovate config) — unchanged from the first
  pass.

## Incident response & operational judgment

New category this pass, scored on how bugs 1-5 above were actually
handled, not just that they existed:

* **Root-caused with evidence, not guesses**, every time — the
  external-dns fix came from reading actual pod logs and matching the
  exact `AccessDenied` principal ARN back to "this is the node role, not
  the Pod Identity role, so the association isn't matching"; the
  metrics-server fix came from tracing an `APIService` discovery failure
  down to a specific missing security-group port, then confirming with
  `kubectl top nodes` afterward rather than assuming the fix worked.
  Every fix in this session has a verification step attached, not just a
  change and a hope.
* **Correctly distinguished "fix the instance" from "fix the class"** —
  bug 4's manual image push got greeter running again immediately, but
  the writeup is explicit that it didn't fix why CI never re-ran; that
  distinction is exactly what separates patching a symptom from
  understanding a system.
* **Knew when *not* to act** — bug 5's fix is identified and correct, but
  deleting a NodeClaim terminates a real EC2 instance, and that class of
  action was left for explicit operator sign-off rather than just running
  it. Restraint on a destructive action under uncertainty about
  authorization is itself a senior signal, not a gap — a more junior
  instinct would be to either force it through or leave the diagnosis
  half-finished.
* **Where this pulls the operational-maturity score down**: none of this
  is proactive. Every bug above was found by a human looking, after the
  fact, not by anything the system itself surfaced. That's the same
  conclusion as the Automation/reliability gaps above, from a different
  angle — the *engineering judgment* applied once a problem is visible is
  consistently strong; the *system's* ability to surface a problem on its
  own is the part still missing.

## Net assessment

The *decisions* in this repo are consistently senior — OIDC-only auth,
least-privilege IAM, real supply-chain security, a maintained decision
log, correct-but-non-obvious infra choices. So is the *incident response*
once a problem is visible — every fix in this reevaluation was root-caused
with real evidence and verified afterward, not patched and assumed. The
*proactive* verification and observability layer is what's still missing:
nothing short of a human looking catches a wrong namespace, a missing
security-group rule, or a node that's been dead for hours, and this repo
still has no automated gate or alert that would surface any of it on its
own. That combination — strong judgment applied reactively, no system
that prompts the judgment to be applied — reads less like a skills gap
and more like a time/scope tradeoff under a challenge deadline: the
documentation and bugfixing landed the second something got looked at,
but nothing yet *makes* something get looked at. Closing that is mostly
CI/policy/observability investment (`terraform plan` in CI,
`tfsec`/`checkov`, `helm template` schema validation, Pod Security
Admission, basic alerting on node/pod health), not new architecture.
