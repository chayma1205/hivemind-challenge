# Project assessment

An honest evaluation of this repo's current state: the engineering level
it represents, what's genuinely strong, and the concrete gaps — security,
automation, and otherwise — that stand between this and a real production
system.

## Scorecard

| Area | Score /10 |
|---|---|
| Architecture & infrastructure design | **9** |
| Security posture | **6** |
| Automation & CI/CD | **7** |
| Observability & reliability | **4** |
| Documentation & process | **8** |
| Incident response & operational judgment | **9** |

**Overall: 7.2/10 — Senior.** This isn't an average across uniformly
mid-level work — it's a spread between consistently senior *judgment*
(architecture choices, incident diagnosis, knowing when to revisit a
decision instead of leaving it "good enough") and mid-level *systemic*
maturity (nothing in the repo catches these classes of bug or failure
before a human looks). A straight numeric average understates the
judgment on display and overstates the operational maturity — read the
per-area sections below, not just the number.

## Seniority level: **Senior**, with a few mid-level gaps that would come up in review

This isn't a junior or mid-level submission. The signals that put it at
senior level:

* **OIDC everywhere, no static credentials, ever** — GitHub Actions → AWS
  via OIDC federation scoped to `ref:refs/heads/main` and `ref:refs/tags/v*`
  only (not `pull_request`), using the newer "immutable subject claim"
  format deliberately because the older name-based format silently
  doesn't match for repos created after 2026-07-15 (`docs/DECISIONS.md`
  documents this was caught via a real failed `AssumeRoleWithWebIdentity`
  call, not assumed).
* **Consistent least-privilege IAM** — every role is scoped to exactly the
  actions/resources it needs: ECR push scoped to two specific repository
  ARNs, Route53 writes scoped to one hosted zone ARN, cert-manager/
  external-dns/Crossplane each get their own narrowly-scoped role rather
  than sharing one, and each is scoped to exactly the actions actually
  used (confirmed live more than once — e.g. Crossplane's Route53 role
  needed both `ChangeResourceRecordSets` *and* `GetHostedZone`, and only
  had the first until an `AccessDenied` in the wild surfaced the gap,
  fixed by widening one statement rather than reaching for `*`). Read and
  write git credentials for the *same* repo are deliberately split
  (repo-server: read-only deploy key; Image Updater: a separate
  write-scoped one) so a compromised sync path can't push.
* **Supply-chain security most senior engineers don't bother with**:
  keyless cosign signing (OIDC identity, Rekor transparency log, no
  signing key to manage), SBOM generation, and SLSA v1 provenance
  attestations, all in the CI pipeline — with a dedicated MUTABLE ECR repo
  for the signatures because cosign rewrites `.sig`/`.att` tags in place,
  which the app image repo's IMMUTABLE tag policy would reject. That's a
  subtle interaction most people miss entirely.
* **A real decision log** (`docs/DECISIONS.md`, 12 entries) — not just
  what was decided but the context, the tradeoff, and — notably —
  decisions *revisited* with dated addenda when circumstances changed
  (public→private repo, single-repo→split-repo CI/CD, and ingress-cert
  ownership bouncing between Crossplane and Terraform twice before
  landing on a real fix) rather than silently rewritten. This is the
  single strongest signal of seniority in the repo: it shows reasoning
  under changing constraints, not just a snapshot, and it shows a
  willingness to admit a prior decision didn't hold up rather than
  quietly patch around it.
* **Correct, non-obvious infrastructure choices**: S3 native locking
  (`use_lockfile`) instead of a DynamoDB table now that Terraform ≥1.11
  supports it; EKS Pod Identity over IRSA for newer AWS-native EKS
  addons (which often don't expose a serviceAccount-annotation surface for
  IRSA at all — confirmed live, not assumed, via
  `aws eks describe-addon-configuration`); GitOps app-of-apps that's
  self-managing (the root `Application` watches its own generator output,
  so a re-generated `argocd-apps.yaml` needs no manual re-apply); a real
  Crossplane Composition (a `function-patch-and-transform` pipeline) for
  per-hostname ACM certs, wiring a certificate's ACM-assigned DNS
  validation record into its Route53 record automatically instead of
  needing a value copied in by hand.

**What would read as a gap in a senior-level review** (see below for the
full list): no automated tests beyond a trivial `go test`, no
policy-as-code / static analysis on the Terraform or Kubernetes
manifests, no Pod-level security hardening on most charts, no branch
protection, no observability beyond raw metrics-server, and several real
bugs that only surfaced under live testing rather than being caught
earlier (see "Bugs found only by running the thing," below) — normal for
a fast-moving solo build, but each one is the kind of thing a second
reviewer or a CI policy gate would have caught before it reached a
running cluster.

## Bugs found only by running the thing

Notable because none of these were visible from reading the code — every
one needed the actual cluster to expose it. Worth calling out because
it's a pattern: components were configured based on reasonable
assumptions (default namespaces, default ports, a value that was correct
when written) that turned out to be wrong or went stale, and nothing in
the pipeline would have caught any of them before a live sync.

1. **external-dns Pod Identity wired to the wrong namespace.** Assumed the
   EKS addon deploys into `kube-system`; it actually uses its own
   `external-dns` namespace. The Pod Identity association silently never
   matched — no error, no crash — the pod just fell back to the EC2 node
   group's IAM role (zero Route53 permissions) and retried
   `route53:ListHostedZones` with `AccessDenied` every 60 seconds for the
   life of the pod. No DNS records were ever created. **Fixed and
   verified**: corrected namespace, restarted the pod, confirmed real
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
   syncs and reports `Healthy`, all AWS provider packages installed.
4. **The split-repo migration left ECR with nothing in it.** After
   `hivemind-greeter` was split out, its CI run was manually cancelled and
   never re-run, so the ECR repo — freshly created by this same
   apply — had zero images. The chart's bootstrap image tag was a stale
   reference to a commit that doesn't exist in the new repo's history at
   all. `ImagePullBackOff` until someone built and pushed an image
   directly by hand. **Fixed**, but by a manual side-channel, not by the
   pipeline that's supposed to own this — the underlying gap (CI never
   re-ran after being cancelled, and nothing noticed) is unresolved.
5. **A Karpenter-provisioned node went unresponsive** — kubelet stopped
   posting status entirely (`Ready: Unknown` → `NotReady`) for hours while
   the underlying EC2 instance stayed `running` in AWS. Several pods sat
   `Terminating` against it until Argo CD's `selfHeal` recreated the
   Deployments elsewhere. The identified fix (`kubectl delete nodeclaim`,
   so Karpenter properly terminates and replaces it) was deliberately
   *not* run — deleting a NodeClaim terminates a real EC2 instance, and
   that action was left for explicit operator sign-off rather than
   executed unilaterally. It eventually resolved anyway, but by an
   unrelated later change (renaming the Karpenter NodePool) that
   cascade-deleted every NodeClaim under the old name, including the hung
   one, as a side effect — not by anyone approving and running the
   documented fix. Worth being precise about that distinction: the
   *diagnosis and restraint* were sound, but the *resolution* was luck,
   not process, and the underlying "nothing pages anyone when a node
   dies" gap is exactly as open now as it was the day this was found.
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
   fix only actually stuck once it was committed and pushed. Worth
   calling out on its own: in a GitOps cluster, *any* direct kubectl edit
   to a resource Argo CD manages with `selfHeal: true` is temporary by
   construction, no matter how correct it is — and this exact mistake
   recurred once more, during bug 7 below.
7. **Building a real Crossplane Composition for ingress certs surfaced
   three more live-only issues**, none of them visible from reading
   Crossplane's own docs, only from actually running the pipeline:
   - The Composition's `functionRef.name` used the Function package's
     short name (`function-patch-and-transform`); the object Crossplane's
     package manager actually installs is named after the full package
     path (`crossplane-contrib-function-patch-and-transform` — the same
     convention already visible on the provider packages, just not
     recognized as a convention until it broke).
   - The `IngressCertificate` composite type is `scope: Namespaced`
     (Crossplane v2's direct-usage mode, no Claim indirection), which
     turned out to require its composed resources to *also* be the
     namespaced (`.m.upbound.io`) managed-resource CRD variant — a
     cluster-scoped composed resource under a namespaced composite fails
     outright (`cannot apply cluster scoped composed resource ... for a
     namespaced composite resource`). That variant, in turn, needs a
     `ClusterProviderConfig` credential object, not the plain
     `ProviderConfig` the rest of the chart already had wired.
   - The Route53 provider's `Record` resource calls `GetHostedZone`
     before it writes, which the existing IAM policy — scoped correctly
     for `ChangeResourceRecordSets` but never asked to read the zone —
     didn't grant, surfacing as a live `AccessDenied`.

   All three **fixed and verified** individually, and the end state
   verified further than "it synced": both ACM certs confirmed `ISSUED`
   via the AWS API, and — before removing the older, now-redundant certs
   — confirmed both ALB listeners had already cleanly switched to the new
   cert ARNs with no ambiguity error and all targets `healthy`, *only
   then* removing the old ones. That ordering mattered: getting it wrong
   would have reproduced bug 6 on purpose.

Six of seven ended up genuinely fixed and independently verified, not
just patched and assumed working. Bug 5 is the honest outlier: resolved,
but by luck rather than the identified remediation ever being executed —
which is itself a data point about the observability gap below, not a
counterexample to it.

## Gaps

### Security

* **No Pod-level hardening on most charts.** The greeter Deployment has a
  pod-level `securityContext` (`runAsNonRoot`, a numeric `runAsUser`) —
  added after the Dockerfile's own `USER nonroot:nonroot` turned out not
  to be enough on its own (`runAsNonRoot: true` needs a *numeric*
  `runAsUser`; a named user in `/etc/passwd` isn't resolvable by kubelet,
  confirmed live via a crash-looping pod). But there's no container-level
  hardening anywhere (no `readOnlyRootFilesystem`, no
  `allowPrivilegeEscalation: false`, no capability drops), and nothing —
  no Pod Security Admission label, no OPA/Kyverno policy — would stop a
  future chart from regressing even the pod-level baseline that exists.
* **No NetworkPolicy anywhere in the cluster.** Every pod can reach every
  other pod by default. For a cluster running cert-manager, Crossplane
  (with real AWS credentials via Pod Identity), and the ALB controller,
  that's a meaningfully flat blast radius if any one workload is
  compromised.
* **Secrets are raw Kubernetes Secrets, no encryption-at-rest story
  beyond EKS's default EBS/etcd encryption.** No External Secrets
  Operator, no AWS Secrets Manager/Parameter Store integration in active
  use, no Sealed Secrets. The git deploy-key Secrets and any future
  application secrets are one `kubectl get secret -o yaml` away from
  plaintext for anyone with cluster read access. (The AWS Secrets Manager
  CSI driver addon is installed, but nothing currently consumes it — it's
  plumbing without a workload wired to it yet.)
* **No policy-as-code on the Terraform.** No `tfsec`, `checkov`, or OPA/
  Conftest gate in CI — nothing would flag a future security-group rule
  that's too broad, an S3 bucket without encryption, or an IAM policy
  drifting toward `*` before it merges.
* **Branch protection couldn't be verified** (GitHub API 403s on a free
  private repo), but from the commit history every change on `main`
  goes straight to `main` with no PR, no required review, no
  status-check gate. Fine for a solo build; a real security gap the
  moment more than one person has push access.
* **No dependency-update automation** — no Dependabot or Renovate config
  anywhere in the repo. Go module and Helm chart versions are all
  hand-pinned with no mechanism to know when a pinned version has a
  disclosed CVE.
* **The EKS public endpoint's allowed CIDR is a single hardcoded IP**
  captured once, with a code comment already flagging it as something
  that goes stale. Correct instinct (restrict public access at all,
  rather than leaving `0.0.0.0/0`), but a static single-IP allowlist is
  itself an operational trap the moment anyone's network changes — worth
  a VPN/bastion or a maintained IP set instead.
* **No `LICENSE`, no `SECURITY.md`.** The legal terms of reuse are
  undefined, and there's no documented vulnerability-disclosure path.

### Automation / reliability

* **No CI validation of the Terraform at all** — no `terraform plan`,
  no `terraform validate`, no drift-detection job. `ci.yml` in this repo
  only lints the greeter Helm chart and checks that `argocd-apps.yaml` is
  up to date with the chart directories; the Terraform side, and every
  other chart in `charts/env/prod/`, has zero automated gate before a
  human applies or syncs it.
* **No integration or infra tests.** The Go app has a trivial `go test`;
  there's no Terratest (or equivalent) exercising the Terraform modules,
  no `helm template` + `kubeconform`/`kubeval` schema validation in CI,
  and — as the seven live-only bugs above show — nothing that would catch
  a wrong namespace, a missing security-group rule, a stale hardcoded
  value, or a wrong CRD scope before it reaches a real cluster.
* **No staging environment that actually exists.** `hivemind-greeter`'s
  `cd-staging.yml` builds and pushes staging-tagged images, but there's
  no staging Kubernetes namespace, Argo CD Application, or cluster for
  those images to ever land on — the pipeline half exists.
* **No observability beyond raw `metrics-server` / EKS's CloudWatch
  defaults.** No log aggregation, no alerting, no dashboards, no SLOs.
  Karpenter's node auto-repair feature gate is enabled, which narrows
  bug 5's specific failure mode going forward, but there's still no
  general node or pod health alerting — if a Pod crash-loops at 3am,
  nothing pages anyone.
* **Several genuinely manual, recurring operational steps by design**
  (documented, deliberate, not accidental): GitHub deploy-key
  registration and the two K8s Secret creations are explicitly
  human-in-the-loop (`docs/DECISIONS.md` #10's stated rationale: an
  agent — or a pipeline — writing credentials into a cluster shouldn't be
  fully automated). Reasonable for a single-operator setup; doesn't scale
  to a team without a proper credential-provisioning mechanism.
* **`docs/DISASTER_RECOVERY.md`'s validation checklist is scoped to bugs
  1-4** and predates bugs 6-7 (stale `vpcId`, Crossplane IAM scope) —
  both are exactly the kind of rebuild regression that checklist exists
  to catch, and neither is on it yet. The procedure itself hasn't been
  exercised end to end either (no from-scratch recovery drill has
  actually been run) — reviewed and plausible, not proven.
* **A recurring process near-miss, not just a monitoring one**: twice in
  this repo's history, a fix was first applied directly to the live
  cluster (`kubectl patch`/`kubectl apply`) and silently reverted by Argo
  CD's own `selfHeal` because it hadn't been pushed to git yet (bugs 6
  and 7 above). Caught and corrected both times, but only by someone
  noticing the drift after the fact — nothing alerts on an Argo CD
  Application flipping `OutOfSync` due to live drift, which is a cheap,
  specific gap to close (an Argo CD notification/webhook on that
  transition) relative to the general observability gap above.

### Documentation / process

* README, ARCHITECTURE.md, RUNBOOK.md, DISASTER_RECOVERY.md, and
  DECISIONS.md all exist and are current with the live state of the
  system — including a shared "bugs found by running the thing" section
  kept consistent between this document and `ARCHITECTURE.md`. CODEOWNERS
  exists, with one blanket rule matching the current single-operator
  reality.
* **Still no `LICENSE`, no `SECURITY.md`** (also listed under Security
  above, since both are as much a security-process gap as a docs one).
* **No dependency-update automation** (also listed under Security above).

## Incident response & operational judgment

Scored on how the bugs above were actually handled, not just that they
existed:

* **Root-caused with evidence, not guesses**, every time — the
  external-dns fix came from reading actual pod logs and matching the
  exact `AccessDenied` principal ARN back to "this is the node role, not
  the Pod Identity role, so the association isn't matching"; the ALB
  `vpcId` fix came from reading the controller's own events (`Evaluated
  0 subnets`) back to a specific stale value in `values.yaml`. Every fix
  has a verification step attached, not just a change and a hope —
  including verifying via the AWS API directly (`describe-certificate`,
  `describe-listeners`, `describe-target-health`) in an environment with
  no outbound path to actually curl the resulting endpoints.
* **Correctly distinguished "fix the instance" from "fix the class"** —
  bug 4's manual image push got greeter running again immediately, but
  it didn't fix why CI never re-ran, and that distinction was stated
  explicitly rather than left implicit. Bug 7 is the positive version of
  the same instinct: the first Crossplane cert attempt's manual-copy gap
  wasn't patched around a second time, it was actually closed with a real
  Composition.
* **Sequenced a live cutover to avoid self-inflicted downtime.** Bug 7's
  fix meant two valid ACM certs existing for the same hostname
  simultaneously during the transition. Rather than deleting the older
  cert once the new one merely *existed*, the sequence was: confirm
  `ISSUED` status via the AWS API, force an ALB reconcile and confirm via
  `describe-listeners` that it had *actually* switched to the new ARN
  with no ambiguity error, confirm target health, and only then remove
  the old cert. Getting this ordering wrong would have reproduced bug 6
  on purpose — the kind of judgment that's easy to skip under time
  pressure and hard to notice missing until it's too late.
* **Scoped a request against a real architectural constraint instead of
  building the wrong thing.** Asked, before writing any code, whether
  cert-manager could actually own ACM certificate issuance for
  ALB-terminated TLS; surfaced that it structurally can't (cert-manager
  issues Kubernetes Secrets; the ALB needs an ACM ARN); got explicit
  direction on the resulting tradeoff before touching a file.
* **Knew when *not* to act** — bug 5's fix (`kubectl delete nodeclaim`)
  was identified and correct, and terminating a real EC2 instance was
  correctly left for explicit operator sign-off rather than run
  unilaterally. It ended up resolved by an unrelated cascade instead,
  which doesn't retroactively make the restraint wrong, but does mean
  this bug's *resolution* isn't evidence of good judgment — only its
  *diagnosis* is.
* **Where this pulls the operational-maturity score down**: none of it
  is proactive. Every bug above was found by a human (or an agent acting
  on a human's behalf) looking, after the fact — not by anything the
  system itself surfaced. The *judgment* applied once a problem is
  visible is well-evidenced and consistently strong across seven
  separate incidents; the *system's* ability to surface a problem on its
  own is the part that doesn't exist yet.

## Net assessment

The *decisions* in this repo are consistently senior — OIDC-only auth,
least-privilege IAM, real supply-chain security, a maintained decision
log that gets revisited rather than silently rewritten, and
correct-but-non-obvious infra choices, including seeing an architecture
decision (ingress-cert automation) through to something that actually
works rather than leaving it at "good enough." So is the *incident
response* once a problem is visible: every fix in this repo's history was
root-caused with real evidence and verified afterward, not patched and
assumed, up to and including a deliberately sequenced production cutover
that avoided reproducing the exact bug it was fixing.

The *proactive* verification and observability layer is what's still
missing, in two related ways. The first is the familiar one: nothing
short of a human looking catches a wrong namespace, a missing
security-group rule, or a node that's been dead for hours, and there's no
automated gate or alert that would surface any of it on its own. The
second is more specific: a live drift near-miss (a direct kubectl fix
getting silently reverted by Argo CD's `selfHeal` because it wasn't
pushed yet) happened twice in this repo's history, caught both times only
by someone going back and checking — a cheap, addressable gap (alerting
on `OutOfSync` transitions caused by drift) sitting right next to the
much larger observability gap.

That combination — strong judgment applied reactively, no system that
prompts the judgment to be applied — reads less like a skills gap and
more like a time/scope tradeoff under a challenge deadline: the
documentation, bugfixing, and architecture correction land the moment
something gets looked at, but nothing yet *makes* something get looked
at on its own. Closing that is mostly CI/policy/observability investment
(`terraform plan` in CI, `tfsec`/`checkov`, `helm template` schema
validation, Pod Security Admission, basic alerting on node/pod health and
on Argo CD drift), not new architecture.
