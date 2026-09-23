# Project assessment

An honest evaluation of this repo's current state: engineering level it
represents, what's genuinely strong, and the concrete gaps — security,
automation, and otherwise — that stand between this and a real production
system. Written 2026-09-22, after the initial EKS/GitOps stack went live;
reevaluated later the same day after README/disaster-recovery docs were
added, three of the four originally-found live bugs were fixed and
verified, and a fifth issue was found in the process. Reevaluated again
2026-09-23 after an ALB-controller bug and a full Crossplane-based
ingress-cert rebuild — see below.

## Scorecard

| Area | Score /10 | Direction since last look |
|---|---|---|
| Architecture & infrastructure design | **9** | — (was already the strongest area) |
| Security posture | **6** | — (no structural change; IAM stayed strictly least-privilege through another round of scope additions, but Pod/network hardening still absent) |
| Automation & CI/CD | **7** | ↑ from 6 — the ACM-automation gap is now actually closed, not just fixed-and-hoped: a real Composition, verified end to end including a zero-downtime cutover |
| Observability & reliability | **4** | — (the previously-dead node came back via an unrelated side effect, not detection — the underlying gap is unchanged) |
| Documentation & process | **8** | — (CODEOWNERS closed; LICENSE/SECURITY.md/dependency automation still open) |
| Incident response & operational judgment | **9** | ↑ from 8 — see below |

**Overall: 7.2/10 — Senior**, up from 6.8. The gain is real, not
grade inflation: one concrete automation gap (ACM cert wiring) that was
explicitly flagged as open in the last pass is now closed and verified
live, and the incident-response evidence from this pass includes a
genuinely senior move — sequencing a production cutover (old cert →
new cert) so it never had a window with zero valid HTTPS cert attached,
rather than just applying the "correct" end state and hoping the gap
was small. The same underlying pattern from the last two passes still
holds, though: judgment applied *once a problem is visible* is
consistently strong; the *system's own* ability to surface a problem
without a human looking is still the weak point. Read the per-area
sections below, not just the number.

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
5. ~~A Karpenter-provisioned node went unresponsive~~ **Resolved**, but
   not by the identified fix — an unrelated later change (renaming the
   Karpenter NodePool) cascade-deleted every NodeClaim under the old
   name, including the hung one, and Karpenter replaced it as a side
   effect. `kubectl get nodes` now shows all nodes `Ready`. Worth being
   honest about: this closed by coincidence, not by someone approving
   and running the documented fix — the underlying "nothing pages anyone
   when a node dies" gap (see Observability below) is exactly as open as
   it was when this was written.
6. **The ALB controller's `vpcId` was hardcoded to a VPC that no longer
   existed**, after a full infra teardown/rebuild — the classic failure
   mode of copying a Terraform output into a chart's `values.yaml`
   instead of deriving it at runtime. Both ingresses (`argocd`,
   `greeter`) silently never got an ALB: `FailedBuildModel ... Evaluated
   0 subnets` in the controller's own events, for 8 hours, because it was
   scanning subnets in a VPC that had been destroyed. **Fixed and
   verified**: cleared the hardcoded value so the controller falls back
   to its own instance-metadata auto-detection (which can't go stale the
   same way), confirmed both ALBs reached `active` with healthy targets.
   The first fix *attempt*, though, was a direct `kubectl patch` on the
   live Deployment — which Argo CD's `selfHeal` silently reverted within
   minutes, because the git-committed chart still had the old value. The
   fix only actually stuck once it was committed and pushed. Filed as
   its own lesson, not just folded into the bug: in a GitOps cluster,
   *any* direct kubectl edit to a resource Argo CD manages with
   `selfHeal: true` is temporary by construction, no matter how correct
   it is — and this exact mistake recurred once more during bug 7 below,
   which says more about how strong the pull toward "just patch it live
   and check" is under time pressure than about either fix being wrong.
7. **Building the real Crossplane Composition for ingress certs surfaced
   three more live-only issues**, each only discoverable by actually
   running the pipeline against a live cluster, not by reading Crossplane's
   docs:
   - The Composition's `functionRef.name` used the Function package's
     short name (`function-patch-and-transform`); the object Crossplane's
     package manager actually installs is named after the full package
     path (`crossplane-contrib-function-patch-and-transform` — the same
     convention already visible on the provider packages, just not
     recognized as a convention until it broke).
   - The `IngressCertificate` XRD is `scope: Namespaced` (Crossplane v2's
     direct-usage mode, no Claim indirection), which turned out to
     require its composed resources to *also* be the namespaced
     (`.m.upbound.io`) managed-resource CRD variant — a cluster-scoped
     composed resource under a namespaced composite fails outright
     (`cannot apply cluster scoped composed resource ... for a namespaced
     composite resource`). That variant, in turn, needs a
     `ClusterProviderConfig` credential object, not the plain
     `ProviderConfig` the rest of this chart already had wired.
   - The Route53 provider's `Record` resource calls `GetHostedZone`
     before it writes, which the existing IAM policy — scoped correctly
     for `ChangeResourceRecordSets` but never asked to read the zone —
     didn't grant, surfacing as a live `AccessDenied`.

   All three **fixed and verified** individually (each confirmed against
   the live cluster before moving to the next), and the end state
   verified further than "it synced": both ACM certs confirmed `ISSUED`
   via `aws acm describe-certificate`, and — before touching the old,
   now-redundant Terraform-managed certs — confirmed both ALB listeners
   had already cleanly switched to the new cert ARNs with no ambiguity
   error and all targets `healthy`, *then* destroyed the old certs. That
   ordering is the point: the same class of self-inflicted downtime as
   bug 6 was avoidable here and was, in fact, avoided.

Six of seven are fixed and independently verified, not just patched and
assumed working. Bug 5 is the honest outlier — resolved, but by luck
rather than the identified remediation being executed, which is itself
a data point about the observability/alerting gap below: nothing made
that fix happen on purpose.

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
  and — as the seven live-only bugs above show — nothing that would catch
  a wrong namespace, a missing security-group rule, a stale hardcoded
  value, or a wrong CRD scope before it reaches a real cluster.
* **No staging environment that actually exists.** `cd-staging.yml` in
  `hivemind-greeter` builds and pushes staging-tagged images, but there's
  no staging Kubernetes namespace, Argo CD Application, or cluster for
  those images to ever land on — the pipeline half exists.
* **No observability beyond raw `metrics-server` / EKS's CloudWatch
  defaults** — explicitly called out as a known gap in
  `docs/ARCHITECTURE.md`. Bug 5 above is still the live example, and the
  way it eventually resolved makes the point sharper, not weaker: it
  came back because an unrelated change happened to delete its
  NodeClaim, not because anything detected or paged on it. No log
  aggregation, no alerting, no dashboards, no SLOs, and — as of this
  reevaluation — no node health monitoring either (Karpenter has no
  auto-repair configured/active here). If a Pod crash-loops at 3am,
  nothing pages anyone; if a *node* dies at 3am, apparently nothing
  notices at all, and getting lucky isn't a fix.
* ~~No documented disaster-recovery procedure~~ **Closed** —
  `docs/DISASTER_RECOVERY.md` now exists, with concrete recovery steps
  for cluster loss, state-bucket loss, hosted-zone loss, bad deploys, and
  credential compromise, plus a validation checklist tied to bugs 1-4
  above so a rebuild doesn't silently reintroduce them. Not yet
  *exercised* end-to-end (nobody's actually run a from-scratch recovery
  drill), so treat it as reviewed-but-untested. **Minor drift**: that
  checklist predates bugs 6-7 below (stale `vpcId`, Crossplane IAM
  scope) — both are exactly the kind of rebuild regression it's meant to
  catch, and neither is on it yet.
* **Several genuinely manual, recurring operational steps by design**
  (documented, deliberate, not accidental): GitHub deploy-key
  registration and the two K8s Secret creations are explicitly
  human-in-the-loop (`docs/DECISIONS.md` #10's stated rationale: an
  agent — or a pipeline — writing credentials into a cluster shouldn't be
  fully automated). Reasonable for a single-operator setup; doesn't scale
  to a team without a proper credential-provisioning mechanism.
* ~~The ACM certificate validation flow has no automation linking
  Certificate → DNS record → CertificateValidation~~ **Closed** — see bug
  7 above for the mechanics. `docs/DECISIONS.md` #12 records the full
  back-and-forth (Crossplane → Terraform → Crossplane) as a first-class
  decision, not a silent rewrite.

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
* ~~Still no CODEOWNERS~~ **Closed** — added (`.github/CODEOWNERS`), one
  blanket rule for the current single-operator reality.
* **Still no SECURITY.md, no dependency-update automation** (no
  Dependabot/Renovate config) — unchanged from the first pass.

## Incident response & operational judgment

Scored on how bugs 1-7 above were actually handled, not just that they
existed:

* **Root-caused with evidence, not guesses**, every time — the
  external-dns fix came from reading actual pod logs and matching the
  exact `AccessDenied` principal ARN back to "this is the node role, not
  the Pod Identity role, so the association isn't matching"; the
  ALB `vpcId` fix came from reading the controller's own events
  (`Evaluated 0 subnets`) back to a specific stale value in
  `values.yaml`, not a guess about DNS or IAM. Every fix has a
  verification step attached, not just a change and a hope — including,
  this pass, verifying via the AWS API directly (`describe-certificate`,
  `describe-listeners`, `describe-target-health`) when the sandbox itself
  had no outbound path to actually curl the resulting endpoints.
* **Correctly distinguished "fix the instance" from "fix the class"** —
  bug 4's manual image push got greeter running again immediately, but
  the writeup is explicit that it didn't fix why CI never re-ran; bug 7
  is the positive version of the same instinct — the first Crossplane
  cert attempt's manual-copy gap wasn't patched around a second time, it
  was actually closed with a real Composition.
* **Sequenced a live cutover to avoid self-inflicted downtime** — the
  clearest new evidence this pass. Bug 7's fix meant two valid ACM certs
  existing for the same hostname simultaneously (old Terraform-managed,
  new Crossplane-managed) during the transition. Rather than deleting the
  old cert once the new one merely *existed*, the sequence was: confirm
  `ISSUED` status via the AWS API, force an ALB reconcile and confirm via
  `describe-listeners` that it had *actually* switched to the new ARN
  with no ambiguity error, confirm target health, and only then destroy
  the old cert. Getting this ordering wrong would have reproduced bug 6
  on purpose. This is the kind of judgment that's hard to fake and easy
  to skip under time pressure.
* **A near-miss pattern, twice** — both bug 6 and bug 7 involved a first
  fix attempt applied directly to the live cluster (`kubectl patch`/
  `kubectl apply`) that Argo CD's `selfHeal` silently reverted because it
  hadn't been pushed to git yet. Caught and corrected both times once the
  drift was noticed, but it's the same mistake recurring in the same
  session, which is a more honest signal than either instance alone: the
  fix belongs in "commit, push, let GitOps converge," and the pull toward
  "just patch it live and verify" is strong enough to override that even
  right after having just relearned it.
* **Scoped a request against a real architectural constraint instead of
  building the wrong thing** — asked (before writing any code) whether
  cert-manager could actually own ACM certificate issuance for
  ALB-terminated TLS, surfaced that it structurally can't (cert-manager
  issues k8s Secrets; the ALB needs an ACM ARN), and got explicit
  direction on the resulting three-way tradeoff before touching a file.
* **Knew when *not* to act** — bug 5's fix (`kubectl delete nodeclaim`)
  was identified and correct, and terminating a real EC2 instance was
  correctly left for explicit operator sign-off rather than run
  unilaterally. It ended up resolved by an unrelated cascade instead —
  which doesn't retroactively make the original restraint wrong, but
  does mean this specific bug's *resolution* isn't evidence of good
  judgment, only its *diagnosis* is.
* **Where this still pulls the operational-maturity score down**: none of
  it is proactive. Every bug above, across both passes, was found by a
  human (or an agent acting as one) looking, after the fact — not by
  anything the system itself surfaced. That's the same conclusion as the
  Automation/reliability gaps above, from a different angle: the
  *judgment* applied once a problem is visible is now well-evidenced
  across seven separate incidents; the *system's* ability to surface a
  problem on its own is still the part that doesn't exist.

## Net assessment

The *decisions* in this repo are consistently senior — OIDC-only auth,
least-privilege IAM, real supply-chain security, a maintained decision
log, correct-but-non-obvious infra choices, and now a second
architecture area (ingress cert automation) that was explicitly revisited
until it was actually right rather than left "good enough." So is the
*incident response* once a problem is visible — seven fixes across two
reevaluation passes, every one root-caused with real evidence and
verified afterward, not patched and assumed, including this pass's most
senior single moment: sequencing a live cert cutover so it never had a
window without a valid, attached ACM cert, rather than applying the
correct end state and hoping the gap between "new cert exists" and "ALB
is using it" was short enough not to matter.

The *proactive* verification and observability layer is still what's
missing, and this pass adds a second dimension to that gap beyond "no
alerting": a *process* near-miss, not just a monitoring one. Twice in
this session, a fix was first applied directly to the live cluster and
silently reverted by Argo CD's own `selfHeal` before anyone noticed —
caught both times, but by inspection after the fact, not because
anything flagged the drift proactively. That's the same shape as the
node-death and missing-security-group-rule findings: the judgment to
recognize and correct each of these was there every time; nothing in the
system itself made the mistake visible without someone going and looking
for it.

That combination — strong judgment applied reactively, no system that
prompts the judgment to be applied — still reads less like a skills gap
and more like a time/scope tradeoff. What's different this pass is that
one whole category from that tradeoff — "cert automation, someday" — got
paid down for real, on the first pass at doing it *properly* rather than
routing around the gap a second time. Closing the rest is the same list
as last time and hasn't moved: `terraform plan` in CI, `tfsec`/`checkov`,
`helm template` schema validation, Pod Security Admission, basic alerting
on node/pod health, and — new, specific, and cheap — an Argo CD
notification or webhook on `OutOfSync` transitions caused by drift, which
would have caught both this session's `selfHeal`-reverted near-misses in
real time instead of on the next manual check.
