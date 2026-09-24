# Project assessment

An honest evaluation of this repo's current state: the engineering level
it represents, what's genuinely strong, and the concrete gaps — security,
automation, and otherwise — that stand between this and a real production
system.

## Scorecard

| Pillar | Score /10 |
|---|---|
| Architecture & infrastructure design | **9** |
| Security posture | **6** |
| Automation & CI/CD | **8** |
| Observability & reliability | **6** |
| Documentation & process | **9** |
| Incident response & operational judgment | **9** |

**Overall: 7.8/10 — Senior.** This isn't an average across uniformly
mid-level work — it's a spread between consistently senior *judgment*
(architecture choices, real-time incident diagnosis, knowing when to
revisit a decision instead of leaving it "good enough") and mid-level
*systemic* maturity (nothing in the repo catches these classes of bug or
failure before a human looks). The two pillars that moved this pass both
moved for the same reason: something that existed only as a design on
paper became something real and running — kube-prometheus-stack actually
deployed (Automation, Observability), CI actually linting every chart
instead of one (Automation), the RUNBOOK/DISASTER_RECOVERY docs actually
checked against a real attempt instead of just written (Documentation,
already reflected). A straight numeric average still understates the
judgment on display and overstates the operational maturity — read the
per-pillar sections below, not just the number.

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
  than sharing one, and gaps get widened by exactly one statement when
  found live (Crossplane's Route53 role needed `GetHostedZone` alongside
  `ChangeResourceRecordSets`, discovered via a real `AccessDenied`) rather
  than reached for `*`. Even a broad AWS-managed policy
  (`AmazonEBSCSIDriverPolicyV2`, for the new EBS CSI driver addon) was a
  deliberate choice, not laziness — explained in `main.tf`'s comment as
  "no useful narrower scope to hand-write for a resource type that
  doesn't exist yet at plan time." Read and write git credentials for the
  *same* repo are deliberately split (repo-server: read-only deploy key;
  Image Updater: a separate write-scoped one) so a compromised sync path
  can't push.
* **Supply-chain security most senior engineers don't bother with**:
  keyless cosign signing (OIDC identity, Rekor transparency log, no
  signing key to manage), SBOM generation, and SLSA v1 provenance
  attestations, all in the CI pipeline — with a dedicated MUTABLE ECR repo
  for the signatures because cosign rewrites `.sig`/`.att` tags in place,
  which the app image repo's IMMUTABLE tag policy would reject.
* **A real decision log** (`docs/DECISIONS.md`, 12 entries) — not just
  what was decided but the context, the tradeoff, and — notably —
  decisions *revisited* with dated addenda when circumstances changed
  (public→private repo, single-repo→split-repo CI/CD, and ingress-cert
  ownership bouncing between Crossplane and Terraform twice before
  landing on a real fix) rather than silently rewritten. This is the
  single strongest signal of seniority in the repo: it shows reasoning
  under changing constraints, not just a snapshot.
* **Correct, non-obvious infrastructure choices**: S3 native locking
  instead of a DynamoDB table; EKS Pod Identity over IRSA for newer
  AWS-native addons (confirmed live, not assumed, via
  `aws eks describe-addon-configuration`); GitOps app-of-apps that's
  self-managing; a real Crossplane Composition (a
  `function-patch-and-transform` pipeline) for per-hostname ACM certs,
  wiring a certificate's ACM-assigned DNS validation record into its
  Route53 record automatically.
* **A deployed observability stack**
  (`charts/env/prod/central-services/kube-prometheus-stack`) built and
  shipped with the same rigor as everything else: node headroom checked
  against real numbers before deciding node placement, security-group
  coverage verified live rather than assumed (avoiding a repeat of the
  metrics-server port gap), EKS control-plane monitors disabled up front
  because EKS doesn't expose them, a `NodeNotReadyTooLong` alert written
  specifically to close a real, named incident from this project's own
  history, and delivery via SNS instead of the originally-requested SES
  specifically to avoid a static credential — reused by Argo CD's own
  Notifications controller rather than standing up a second alerting
  path.

**What would read as a gap in a senior-level review** (see the checklist
below for the full list): no automated tests beyond a trivial `go test`,
no policy-as-code / static analysis on the Terraform or Kubernetes
manifests, no Pod-level security hardening on most charts, no branch
protection, a Karpenter NodePool with no minimum instance size (already
causing a stuck pod on an undersized node), and several real bugs that
only surfaced under live testing — including, most recently, a live
full-teardown attempt that surfaced undocumented hazards in the repo's
own teardown procedure, and the rebuild that followed it finding two
more.

## Bugs and incidents found only by running the thing

None of these were visible from reading the code — every one needed the
actual cluster (or a real destructive operation against it) to expose
it.

1. **external-dns Pod Identity wired to the wrong namespace.** Assumed
   `kube-system`; the addon actually uses its own `external-dns`
   namespace. The association silently never matched — the pod fell back
   to the node group's IAM role (zero Route53 permissions) and retried
   with `AccessDenied` every 60 seconds. **Fixed and verified.**
2. **metrics-server unreachable cluster-wide** — the EKS module's default
   security-group rules missed metrics-server's aggregated-API port
   (10251). Every HPA reported `<unknown>` targets, cascading into Argo
   CD marking unrelated Applications `Degraded`. **Fixed and verified.**
3. **Crossplane's own CRD templates raced its own bootstrap** — Argo CD
   validates every resource's GVK *before* wave-sequencing starts, so a
   `DeploymentRuntimeConfig` applied in the same wave as the Deployment
   that registers its CRD failed the entire sync batch, every retry.
   **Fixed and verified** (`SkipDryRunOnMissingResource=true`).
4. **The split-repo migration left ECR with nothing in it** — a cancelled
   CI run that never re-ran, combined with a chart pinned to a commit
   that doesn't exist in the new repo. **Fixed** by a manual image push,
   not by the pipeline that's supposed to own this — that underlying gap
   is unresolved.
5. **A Karpenter-provisioned node went unresponsive for hours**, unpaged.
   The correct fix (`kubectl delete nodeclaim`) was deliberately not run
   without operator sign-off — restraint on a destructive action under
   uncertainty. It eventually resolved by an unrelated NodePool rename
   cascade-deleting the hung NodeClaim, not by anyone running the fix —
   evidence for the observability gap, not against it.
6. **The ALB controller's `vpcId` was hardcoded to a VPC destroyed in an
   earlier rebuild.** Both ingresses silently never got an ALB for 8
   hours (`Evaluated 0 subnets`). **Fixed and verified**, but the first
   fix *attempt* — a direct `kubectl patch` — was silently reverted by
   Argo CD's `selfHeal` within minutes because it hadn't been pushed to
   git. The fix only stuck once committed and pushed.
7. **Building a real Crossplane Composition surfaced three more
   live-only issues** in sequence: a `functionRef` using the Function
   package's short name instead of its actual installed object name; a
   namespaced composite requiring namespaced composed resources *and* a
   `ClusterProviderConfig` (not the plain `ProviderConfig` already
   wired); and a missing `route53:GetHostedZone` grant. **All fixed and
   verified**, including a deliberately sequenced zero-downtime cutover
   from the old certs to the new ones (confirm `ISSUED` → confirm the ALB
   actually switched → confirm target health → *then* remove the old
   certs).
8. **A live full-teardown attempt surfaced three undocumented
   teardown-ordering hazards**, none visible from `docs/RUNBOOK.md`'s
   existing "Tear down" section:
   - ALB-controller-created load balancers aren't Terraform resources.
     Destroying the VPC before deleting their owning Ingress objects
     would have left orphaned ENIs blocking subnet/security-group
     deletion.
   - Argo CD is self-managing — deleting its own Application deletes
     Argo CD's own control plane, which then can't finish processing
     *any* pending Application deletion, including its own. GitOps
     eating itself mid-cascade.
   - Karpenter-launched EC2 instances are real AWS resources outside
     Terraform state too, and Karpenter's controller actively relaunches
     replacement capacity if nodes are removed while pods still need
     somewhere to run — a live tug-of-war, not a one-shot cleanup, until
     the controller itself is stopped first.
   - Separately, the exact risk `docs/DECISIONS.md` #6 already named —
     a single hardcoded IP on the EKS public endpoint — happened live:
     the operator's egress IP drifted mid-operation and `kubectl` access
     dropped entirely, needing a direct `aws eks update-cluster-config`
     call to restore it before anything else could proceed.

   Each hazard was root-caused and worked around in turn (delete
   Ingress → confirm the ALB actually gone via the AWS API *before*
   touching Terraform; stop Karpenter's controller directly rather than
   fighting its reconciliation loop; widen the CIDR live rather than
   through a blocked Terraform apply, since the whole stack was about to
   be destroyed anyway). **Not completed end-to-end**, though — the
   operator took over the remainder manually partway through. This is
   simultaneously the best real-world evidence in this repo of live
   incident diagnosis under pressure, and the actual disaster-recovery
   drill `docs/DISASTER_RECOVERY.md` names as never having been run —
   run for the first time this pass, and it found real gaps.
9. **The rebuild-from-scratch that followed bug 8 found two more live
   bugs**, neither visible from reading the code, both in the
   `aws-ebs-csi-driver` addon added earlier this session — its own first
   real test:
   - `AmazonEBSCSIDriverPolicyV2`'s ARN was wrong (`service-role/`
     doesn't belong in its path) — failed `AttachRolePolicy` with
     `NoSuchEntity` live, cascading into a 20-minute EKS addon timeout
     waiting for a controller pod that could never authenticate. Fixed
     against the real ARN, confirmed via `aws iam list-policies`.
   - The exact same CIDR risk from bug 8 — recurred a *second* time in
     one session, this time on a freshly created cluster (not a live one
     drifting), proving it isn't a one-off. Fixed in Terraform this time
     (`variables.tf`'s default), not just patched live.

   Both **fixed and verified** — the second apply succeeded cleanly.
   Also surfaced, separately, a real capacity finding left as a known
   issue rather than fixed unilaterally: Karpenter's NodePool has no
   minimum instance size, so it picked a `c7a.medium` (8-pod cap) too
   small to hold this cluster's now-larger baseline DaemonSet count —
   confirmed live via a permanently `Pending` node-exporter pod pinned
   by nodeAffinity to that one undersized node. Documented in
   `charts/env/prod/central-services/kube-prometheus-stack/README.md`
   rather than silently changed, since raising the NodePool's minimum
   size is a real cost/capacity tradeoff, not a bug fix.

## Gaps checklist

Only currently-open items — anything closed during this project's
history has been removed rather than kept around as a crossed-off entry.

### Security

- [ ] No Pod-level hardening beyond `securityContext` on greeter
      (`runAsNonRoot` + numeric `runAsUser`, added after a real
      crash-loop). No `readOnlyRootFilesystem`, no
      `allowPrivilegeEscalation: false`, no capability drops anywhere,
      and no Pod Security Admission label or OPA/Kyverno policy to stop
      regressions.
- [ ] No `NetworkPolicy` anywhere in the cluster — every pod can reach
      every other pod by default, including ones holding real AWS
      credentials via Pod Identity (Crossplane, external-dns,
      cert-manager).
- [ ] No secrets-at-rest story beyond EKS's default EBS/etcd encryption —
      no External Secrets Operator, no active Secrets Manager/Parameter
      Store integration (the CSI driver addon is installed but unused),
      no Sealed Secrets.
- [ ] No policy-as-code on the Terraform — no `tfsec`, `checkov`, or OPA/
      Conftest gate in CI.
- [ ] Branch protection unverified/likely absent — every change on `main`
      has gone straight to `main`, no PR, no required review, no
      status-check gate.
- [ ] No dependency-update automation — no Dependabot/Renovate config
      anywhere.
- [ ] The EKS public endpoint's allowed CIDR is a single hardcoded IP —
      already flagged as a known trap in `docs/DECISIONS.md` #6, and it
      actually happened live during the teardown drill (bug 8 above),
      not just a hypothetical anymore.
- [ ] No `LICENSE`, no `SECURITY.md`.

### Automation / CI/CD

- [ ] No CI validation of the Terraform at all — no `terraform plan`, no
      `terraform validate`, no drift-detection job.
- [ ] No integration or infra tests — no Terratest, no `helm template` +
      `kubeconform`/`kubeval` in CI (CI does now lint every chart, not
      just greeter's — but linting isn't schema/cluster validation).
      Every one of the 9 incidents above is a class of bug this would
      have caught before a live sync.
- [ ] No staging environment that actually exists — `cd-staging.yml`
      builds images with nowhere to deploy them.
### Observability / reliability

- [ ] No log aggregation, no dashboards beyond Grafana's shipped
      defaults, no SLOs — metrics/alerting/dashboards exist now
      (`kube-prometheus-stack`, deployed), but nothing ingests logs and
      nothing beyond the shipped Grafana dashboards has been built.
- [ ] Karpenter's node-repair feature gate covers unresponsive
      Karpenter-managed nodes; the EKS-managed system node group has no
      equivalent auto-repair or alerting.
- [ ] Karpenter's NodePool has no minimum instance size — it can (and
      did, live) pick an instance too small to hold this cluster's
      baseline DaemonSet count, leaving a permanently `Pending`
      DaemonSet pod pinned to that one undersized node with nowhere else
      it can schedule. See
      `charts/env/prod/central-services/kube-prometheus-stack/README.md`
      for the specifics; fix is raising the NodePool's minimum size, a
      cost/capacity tradeoff left for a deliberate decision.

## Incident response & operational judgment

Scored on how the incidents above were actually handled, not just that
they existed:

* **Root-caused with evidence, not guesses**, every time — from matching
  an exact `AccessDenied` principal ARN back to a namespace mismatch, to
  reading `Evaluated 0 subnets` back to a stale hardcoded value, to (this
  pass) diagnosing a fully unreachable Kubernetes API down to a specific
  IP-CIDR mismatch by comparing `aws eks describe-cluster`'s allowed
  range against a live `checkip.amazonaws.com` call rather than guessing
  at network causes.
* **Sequenced destructive changes to avoid self-inflicted damage** —
  twice, in two different contexts. Bug 7's cert cutover confirmed the
  new state was actually live before removing the old one. Bug 8's
  teardown attempt deleted Ingress objects and confirmed ALBs were
  actually gone via the AWS API *before* Karpenter's controller was
  stopped and *before* Terraform ever touched the VPC — the same
  discipline applied under much higher time pressure and much less
  certainty about what would go wrong next.
* **Adapted when the planned approach stopped working, without
  panicking or working around the safety rails.** When `kubectl`
  access disappeared mid-teardown, the response was to diagnose why
  (not retry blindly), find a fix that didn't require the blocked
  Terraform path, and apply the narrowest version of that fix (a single
  `/32` CIDR update, not a blanket `0.0.0.0/0` opened "since it's getting
  destroyed anyway"). When Karpenter kept relaunching nodes faster than
  they could be removed, the response was to stop fighting the
  symptom and address the actual cause (the controller itself), not to
  keep terminating instances in a loop.
* **A recurring process near-miss, named honestly rather than glossed
  over** — a live `kubectl` fix getting silently reverted by Argo CD's
  own `selfHeal` because it wasn't pushed yet happened twice (bugs 6 and
  7), and is called out explicitly as a pattern worth fixing
  (Argo CD Notifications on drift), not just a one-off mistake.
* **Knew when to stop and hand off** — both to a human decision point
  (bug 5's NodeClaim deletion, left for explicit sign-off) and, this
  pass, mid-operation: the live teardown was not completed
  autonomously — the operator took it over partway through. Worth
  stating plainly rather than implying a clean finish: the diagnosis and
  the partial remediation were sound, but "the operator decided to take
  back manual control of a live destructive operation" is itself a
  signal worth listening to, not a detail to omit.
* **Where this still pulls the operational-maturity score down**: every
  incident above, across the project's whole history, was found or
  triggered by a human (or an agent acting on one's behalf) actively
  doing something — never by the system surfacing a problem on its own.
  The kube-prometheus-stack spec is a real step toward closing that, but
  it isn't live yet, so today the answer is unchanged: nothing pages
  anyone, and nothing would have caught any of the 8 incidents above
  before someone went looking.

## Net assessment

The *decisions* in this repo are consistently senior, and now include a
second full architecture area (observability) not just designed but
actually deployed, with the same rigor as everything already live —
checked, not assumed, at every step (node headroom, security-group
coverage, EKS-control-plane monitor applicability). The *incident
response* is consistently senior too, evidenced across nine separate
incidents now, including one — a live full-teardown attempt — that is
exactly the kind of high-stakes, ambiguous, multiple-simultaneous-failures
scenario that separates people who can debug from people who can debug
*under pressure, while the ground is moving*, and a follow-up rebuild
that found two more real bugs (one from this project's own recent work)
rather than declaring victory once the teardown itself was handled.

What's unchanged is the shape of the gap: nothing in this system is
proactive *on its own*, though two real pieces of that closed this pass
— a `NodeNotReadyTooLong` alert and Argo CD Notifications on drift are
both live now, not aspirational. What's still true: every one of the
nine incidents in this project's history was found by a human looking,
not flagged automatically before someone went looking for it. The
teardown drill made the deeper version of that concrete — it didn't just
demonstrate the observability gap, it demonstrated that the repo's own
*procedures* (the RUNBOOK's teardown section) hadn't been checked
against reality either, for exactly the reason `docs/DISASTER_RECOVERY.md`
already flagged: an unexercised procedure is a belief, not a fact, and
the first real exercise of one in this project immediately found three
things it was wrong about — then the rebuild that followed found two
more, in code that had already been written and reviewed earlier in the
same session. Closing what's left is a shorter list now: `terraform
plan` in CI, `tfsec`/`checkov`, schema validation, Pod Security
Admission, log aggregation, and a Karpenter NodePool minimum instance
size (found live, left as a decision rather than changed
unilaterally) — plus, still, no automated way to catch the next version
of any of this before a human runs into it.
