# Agent Dogfood: Reference Node Image Builder — Design & MVP Plan

Tracking issue: `azure-management-and-platforms/cloud-native-oss#32`

## Status

Repo: https://github.com/mboersma/imogen (Go, Apache 2.0).

Done:
- Go MCP tool server scaffolding (`cmd/imogen-toolserver`, `internal/tools`).
- Tool `list-k8s-releases` (upstream Kubernetes releases).
- Tool `list-gallery-versions` (Azure compute gallery contents).
- Azure foundation scripts (`hack/setup-foundation.sh`): resource group, staging +
  community galleries, per-flavor image definitions. Parameterized via `IMOGEN_*`.
  Live in the dev subscription; will be swapped for the CNCF galleries later.
- Tools `submit-build-job` / `get-build-status` with `hack/setup-build-identity.sh` +
  `hack/run-build-job.sh` / `hack/build-status.sh`: image-builder runs as a Kubernetes Job on the
  CAPZ builder cluster (`deploy/build-job.yaml`), publishing to the staging gallery. The Job pod
  authenticates with the build managed identity exposed on the builder VMSS through IMDS, then runs
  `az login --identity` + `USE_AZURE_CLI_AUTH=True` (no service principal secret). `run-build-job.sh`
  scales the builder pool up to one worker if idle and returns the Job name; the agent polls
  `get-build-status`. Verified end-to-end: ubuntu-2404 builds published to `imogen_staging`. The build
  pins the real Kubernetes version (semver, series, deb/rpm) so the gallery version label matches what
  is installed. The deb revision is looked up from the community apt repo rather than assumed to be
  `-1.1`, since the release team occasionally rebuilds a patch's packages and bumps it (1.36.2 shipped
  as `-2.1`); image-builder installs the pinned `kubernetes_deb_version` verbatim, so a stale guess
  fails the Ansible install.
- Tools `promote-image` / `get-promote-status` with `hack/promote-image.sh`: `promote-image` submits
  the staging→community copy with `az --no-wait` and returns immediately, then the agent polls
  `get-promote-status` for the community version's provisioningState until Succeeded. Submitting
  asynchronously keeps the gallery create from tripping the MCP client's 300 second timeout (which the
  agent had narrated as success). Verified end-to-end: promoted `1.34.9` into `imogen_community`.
- kagent agent wired and verified on a local kind cluster. The tool server runs in cluster
  over streamable HTTP (`Dockerfile`, `deploy/toolserver.yaml`), exposed to kagent through a
  `RemoteMCPServer`. An `Agent` plus an Azure OpenAI `ModelConfig` (gpt-4.1-mini) drives the
  imogen tools. `hack/setup-openai.sh` creates the Entra-only Azure OpenAI resource;
  `hack/setup-kagent.sh` builds and loads the image and applies the manifests. Verified: the
  agent answered "which Kubernetes releases are in scope?" by actually calling
  `list-k8s-releases` over MCP.

Auth note: this subscription disallows API-key auth on Azure OpenAI, and this kagent version's
Azure client only sends the api-key header. On AKS an in-cluster proxy (`cmd/imogen-aoai-proxy`)
fronts the account and injects a fresh Entra token per request with workload identity, so the
ModelConfig carries no token. Local kind patches a short lived token into the ModelConfig directly.

- CAPZ builder cluster stood up and verified. `hack/setup-mgmt-cluster.sh` creates an AKS
  management cluster with workload identity, a user-assigned identity CAPZ uses (federated to the
  capz-manager and ASO service accounts, no secrets), and runs `clusterctl init`.
  `hack/setup-builder-cluster.sh` creates a self-managed "builder" workload cluster with one VMSS
  MachinePool, then installs Calico and the external Azure cloud provider so nodes go Ready.
  `hack/scale-builder.sh <n>` scales the pool imperatively. Verified: the cluster came up with
  workload-identity auth (ASO created the Azure network with federated tokens), nodes reached
  Ready, and the pool scaled 1 to 0 to 1.
- Image validation with `hack/validate-image.sh`. It boots one node from a staging gallery image
  on the builder cluster (`deploy/validation-machinedeployment.yaml`), waits for Ready, asserts the
  kubelet version matches and the runtime is containerd, runs a `hostNetwork` smoke pod, then tears
  down. The node skips drain on teardown so a broken CNI does not block deletion, and the image is
  replicated to the builder region first. Verified end-to-end: `ubuntu-2404` `1.34.9` booted, ran
  kubelet v1.34.9, and scheduled a pod. The `validate-image` MCP tool wraps this script.
- End-to-end agent demo. The kagent agent drove the fast path live: it read the staging and
  community galleries, validated the `ubuntu-2404` `1.34.9` staging image on the builder cluster,
  asked for approval, and on approval promoted it to the community gallery. Tools added or improved
  for this: `validate-image`, and `list-gallery-versions` now takes `stage` (staging or community)
  and `flavor` so the agent does not need to know gallery names or the `capi-` definition prefix.

Local demo wiring: on kind there is no workload identity to authenticate `az`, so the full pipeline
is driven with the tool server running on the host (`hack/run-toolserver-host.sh`) and the
`RemoteMCPServer` pointed at `host.containers.internal`. The agent in kind reaches it there. This
is the local path only; the durable home is the tool server in AKS with workload identity.

In-cluster tool server. `hack/setup-kagent-aks.sh` deploys kagent and the tool server into the AKS
management cluster with workload identity, so the Azure-backed tools run in cluster with no secrets
and the host hack is gone. The image now bundles `az` and `kubectl` and is built with `az acr build`
(cloud side, no local cross-arch build). A dedicated `imogen-toolserver` identity gets the roles it
needs on the `imogen` resource group and is federated to the tool server service account;
`validate-image.sh` runs in-cluster, reading the builder kubeconfig from its secret. Verified live:
`az` authenticates as the workload identity, lists the galleries, and reads the builder kubeconfig;
the agent discovered all six tools. Because this kagent version still only sends the api-key header,
the model call needs an Entra Bearer token, but that token lives only about 74 minutes and putting it
on the `ModelConfig` folds it into kagent's agent `config-hash`, so every refresh rolls the agent and
kills the in-flight reconcile (and refreshing rarely enough to avoid the roll lets the token expire
mid-run). So in AKS an in-cluster reverse proxy (`cmd/imogen-aoai-proxy`) fronts Azure OpenAI: it
holds its own workload identity, mints and refreshes the token, and injects it per request, while the
`ModelConfig` points at the proxy with no token at all. The local kind path keeps the simpler direct
approach, patching a short lived token into the `ModelConfig` `defaultHeaders`.

Reconstructibility check. After Azure deallocated the dev VMs overnight, we tore the builder cluster
down and rebuilt it from the scripts to test repeatability. It worked but needed manual fix-ups:
the AKS nodes could not restart (`Standard_B2s` is `SkuNotAvailable` in `eastus2`, so we moved to
`Standard_B2s_v2`), the CAPZ teardown stalled on draining the unreachable nodes and the KCP
pre-terminate hook, and a rebuild raced with leftover CAPI objects. The findings and hardening ideas
are in [agentic-dev-feedback.md](agentic-dev-feedback.md). The `eastus2` capacity restrictions keep
moving: `Standard_B2s_v2` later became restricted too, so the mgmt system pool now runs on
`Standard_D2as_v5`.

Image-builder now runs as a Kubernetes Job on the builder cluster (`deploy/build-job.yaml`,
`hack/run-build-job.sh`), authenticated with the build managed identity through IMDS, replacing the
earlier standalone Azure Container Instances build. The builder MachinePool keeps hitting `eastus2`
capacity restrictions: `Standard_B4s_v2` became restricted mid-build, so the pool moved to
`Standard_D2as_v5` (later `Standard_D2as_v4` as restrictions kept shifting).

Autonomous release watcher. `deploy/release-watcher.yaml` is a daily CronJob that runs
`hack/reconcile.sh`, which posts a standing reconcile prompt to the agent over A2A and lets the agent
do the gap analysis and run the pipeline itself. Verified live end to end: the watcher fired, the
agent called `list-k8s-releases` and `list-gallery-versions`, found `ubuntu-2404` versions missing
from the community gallery, called `submit-build-job`, scaled the builder pool to one worker, and the
build Job ran to completion and published `1.35.6` to `imogen_staging`. This surfaced a namespace
bug: the mgmt-side CAPI objects live in `default` but the tool server pod's namespace is `kagent`, so
`run-build-job.sh` and `validate-image.sh` now name the CAPI namespace explicitly
(`IMOGEN_CAPI_NAMESPACE`). It also surfaced an autonomy gap: on the first run the agent stopped to ask
"should I keep waiting?" mid-build, so the reconcile prompt now tells it to poll on its own and only
pause for the promote approval gate.

Reliability gap (fixed): the per-flavor gap analysis used to be done by the model reasoning over the
`list-k8s-releases` and `list-gallery-versions` outputs, and it repeatedly got the set difference
wrong once more than one flavor was in scope. On 2026-07-02 the daily watcher listed every gallery
correctly but then concluded "all in-scope versions are already present" and did nothing, even though
`ubuntu-2604` was missing 1.35.6/1.34.9 and `azurelinux-3` was missing 1.34.9. Prompt hardening ("check
every in-scope version against the community list") did not fix it. The fix moved the gap computation
into deterministic code: the `list-reconcile-plan` tool diffs the in-scope releases against both
galleries in Go and returns the exact work list (`build` or `validate-promote` per flavor and version),
so the model just executes the list rather than deriving it. Verified live on 2026-07-02: the agent
called `list-reconcile-plan` first, got the correct work list (`validate-promote ubuntu-2604 1.35.6`
plus `build` items for `ubuntu-2604 1.34.9` and `azurelinux-3 1.34.9`), and backfilled all three
minors so every in-scope flavor now carries 1.34.9/1.35.6/1.36.2.

Reliability gap (fixed): the status-polling loop used to be unthrottled, so a long run's many
`get-build-status`/`get-validation-status`/`get-promote-status` polls (each a full LLM turn resending
the growing conversation) exhausted the Azure OpenAI deployment's tokens-per-minute quota and failed
the run with a 429. The model cannot pace itself, so the pacing now lives in the tools: each status
poll blocks `IMOGEN_POLL_DELAY_SECONDS` (default 15) before returning, capping the loop rate.

The agent then drove the rest of the loop end to end: with the builder control plane recreated at a
current 1.36 minor it validated the freshly built `1.35.6` staging image, paused at the human approval
gate, and on approval promoted `1.35.6` to the community gallery. That closes the MVP: a full
build → validate → approve → promote run driven by the agent.

Unattended watcher loop (done). The daily watcher now runs the whole pipeline without a human.
`hack/reconcile.sh` no longer depends on a single SSE stream surviving a long build: it follows the
agent's A2A task and, when the stream drops before the task reaches a terminal state, resubscribes
(`tasks/resubscribe`) to the same task and keeps following it until the task completes or
`IMOGEN_RECONCILE_TIMEOUT` (default 5400s) passes. The promote approval gate is the one explicitly
automated exception in this context: with no human watching, the reconcile prompt authorizes the
agent to promote a validated image without asking (`IMOGEN_RECONCILE_AUTO_PROMOTE=1`, default), while
interactive runs through the kagent UI still hit the gate in the agent's system message. Retirement
is never automated; the watcher only ever reports `gc-eol-images` candidates.

Temporary build resource group cleanup (done). Packer builds in a temporary resource group it
creates and deletes itself on success or a graceful failure, but a hard failure (the build pod
killed, the node deallocated, an activeDeadline timeout) can leak it. In this shared subscription we
cannot blindly delete `pkr-Resource-Group-*` groups, so the build Job now tags Packer's `azure_tags`
with an `imogen-build` marker (a `jq` patch of `packer.json` before `make`) and `hack/gc-build-rgs.sh`
deletes only groups carrying that marker, named like a Packer temp group, and older than
`IMOGEN_BUILD_RG_TTL` (default 3h, beyond any real build) so a running build is never disturbed. It is
a dry run by default; `--apply` deletes. `hack/run-build-job.sh` runs the sweep before each build, so
a leak from one run is collected on the next. `promote-image` is already submit-then-poll (paired with
`get-promote-status`) so it no longer trips the MCP client's 300 second timeout.

Observability and audit log (done). Every tool call is audited. `internal/tools/audit.go` wraps each
tool with `auditedTool` so every call records the tool name, input arguments, success or failure,
error, and duration. Each event is written to stderr as a structured JSON line (so it lands in the
pod logs and Azure Monitor; stderr keeps it clear of the stdio MCP transport) and kept in an
in-memory ring buffer (`IMOGEN_AUDIT_BUFFER_SIZE`, default 200) that the `get-audit-log` tool reads
back, so the agent can report what the system has done or diagnose a failed run on demand. This
delivers the MVP's "basic observability/audit log of every tool action."

Notifications (done). The `notify` tool pushes a status update or approval request out to a human
channel so the unattended watcher is visible when no one is watching the A2A stream. When
`IMOGEN_NOTIFY_WEBHOOK_URL` is set (injected from the optional `imogen-notify` Secret), notify POSTs
the message to that Slack/Teams webhook in the incoming-webhook shape (`{"text": ...}`); otherwise it
falls back to the log only, with the message still captured in the audit log. It never gates the
pipeline: `level=approval` only surfaces a request, and a delivery failure is reported but not fatal.
The reconcile prompt ends each watcher run with a `notify` summary and raises a `level=approval`
notification when a human is needed.

Image retirement is in place. `gc-eol-images` closes the lifecycle with a deliberately conservative
policy: downstream projects (cloud-provider-azure, cluster-autoscaler) keep testing against
out-of-support Kubernetes releases and pin specific patches, so the tool retires whole minors only,
never individual patches. It looks up each minor's upstream end-of-life date from endoflife.date and
retires a gallery version only once its minor is past EOL by a grace period (`graceDays` /
`IMOGEN_GC_GRACE_DAYS`, default 365). A minor still supported, within grace, or with no known EOL
date is kept. It defaults to a dry run that only reports the candidates and deletes only with
`apply=true`, since removing image versions is destructive; the agent runs a dry run and asks for
approval first, and the release-watcher only reports candidates. `hack/gc-eol-images.sh` is the
manual equivalent.

Validation version skew. Driving the watcher end to end surfaced that the builder cluster's control
plane (then v1.34.8) could not validate a 1.35.6 image: a node's kubelet may run up to two minors
behind the kube-apiserver but never ahead, so a worker newer than the control plane fails CAPI's
version-skew preflight. The fix is to keep the builder/validation control plane at the newest in-scope
minor; from there a single cluster validates that minor and the supported older ones. The builder is
ephemeral, so we recreate it at the target version (default `IMOGEN_BUILDER_K8S_VERSION` is now a 1.36
CAPI reference image) rather than upgrading in place, since a control-plane upgrade can only step one
minor at a time. CAPI's MachineSet preflight then blocks even an older worker (its `KubeadmVersionSkew`
check wants the worker to match the control-plane minor exactly), so the validation MachineDeployment
carries `machineset.cluster.x-k8s.io/skip-preflight-checks`. With the v1.36.1 control plane in place,
the agent validated and promoted `1.35.6` to the community gallery end to end through the approval
gate.

Unattended reliability fixes. Running the watcher live surfaced three problems, now fixed. First,
long reconciles stalled partway through on Azure OpenAI auth. This kagent version only sends the
api-key header, so the model call needs an Entra Bearer token that lives only about 74 minutes.
Placing it on the `ModelConfig` folds it into kagent's agent `config-hash`, so every refresh rolls
the agent and kills the in-flight turn, yet refreshing rarely enough to avoid the roll lets the token
expire mid-run and the calls return 401. A kagent A2A turn runs server-side and survives an SSE
client disconnect, so the reconcile stream dropping was never the cause. The fix keeps the token off
the `ModelConfig` entirely: an in-cluster reverse proxy (`cmd/imogen-aoai-proxy`) fronts Azure OpenAI
with its own workload identity, minting and refreshing the token and injecting it per request, so the
agent never rolls and never goes stale. Second, `validate-image` blocked for several minutes and
tripped the MCP client's 300 second timeout, which the agent then wrongly retried. Like
`submit-build-job` and `promote-image`, it now starts the validation in the background and returns
immediately, and the agent polls a new `get-validation-status` tool until Succeeded or Failed.
Third, gallery versions are immutable, so there was no way to rebuild a version already in the
community gallery in place. `promote-image` now takes `replace=true` (and `hack/promote-image.sh` a
`--replace` flag) to delete the existing community version and recreate it from validated staging,
with a brief window where it is absent; the watcher never uses it. Verified live end to end: with
`1.34.9` deleted from both galleries, the daily watcher rebuilt it, validated it through the new
non-blocking poll, and promoted it back to the community gallery in one unattended run with no
mid-run restart.

Patch-day stress test (in progress). To surface production hiccups before they happen for real, we
emptied both galleries and ran the watcher against the full 5 flavors × 3 minors matrix with
auto-promote and `gc-eol-images apply=true`. It found three orchestration problems, all fixed in
deterministic code rather than by asking the model to behave. First, parallel validations collided on
the single shared validation MachineDeployment; `validate-image` now serializes per OS type (one
Linux and one Windows validation at a time, the rest queued in server-side goroutines that persist
across agent turns). Second, the agent quit before the matrix finished even when told not to (a
prompt-based "completion gate" was simply ignored by the LLM), so `hack/reconcile.sh` now loops,
re-invoking the agent each pass until `list-reconcile-plan` reports `upToDate` or the deadline
passes; builds and validations keep running server-side between passes and `submit-build-job` /
`validate-image` are idempotent, so each pass just promotes whatever finished. Third, and most
serious, the agent promoted images whose validation had not passed (it called `promote-image` while
validation was still Running, and those validations later failed), publishing unvalidated images.
Prompt wording did not stop it, so `promote-image` now refuses to promote unless that flavor and
version's validation `Succeeded` (`IMOGEN_PROMOTE_REQUIRE_VALIDATION=0` to bypass). The lesson across
all three: persistence and safety invariants must live in the shell loop and the Go tools, never in
the prompt.

The stress test also surfaced two genuine Windows problems, both since fixed. First, Windows VMs
intermittently failed Azure provisioning with `OSProvisioningTimedOut`: after image-builder's
`sysprep /generalize` the built-in Administrator is left flagged "must change password at next logon",
and on first boot the OOBE auto-logon can block on that LogonUI dialog until Azure's provisioning
window expires (a timing race, so the same image sometimes provisions and sometimes times out). A
pre-sysprep Packer provisioner in `deploy/build-job.yaml` disables the built-in Administrator (which
cloudbase-init still renames to `capi` and re-passwords post-OOBE) and stops the packer build user's
password from expiring; three back-to-back boots of the patched image then provisioned cleanly.
Second, once booted the node could stay NotReady: Calico's HNS vSwitch creation freezes the kubelet's
apiserver connection, and the image's in-bootstrap `RestartKubelet.ps1` runs too early to recover it.
`validate-image.sh` now self-heals, restarting the kubelet whenever its node heartbeat stops advancing
until the node goes Ready. With both fixes, windows-2022 1.34.9 passed validation three times
unattended. The provisioning fix is a candidate to upstream into image-builder.

Running the watcher this long also exposed a give-up gap, now fixed. A version that could not be built
or validated (a broken Windows image, or a persistent Azure capacity failure) kept coming back as a work
item every reconcile pass, so the loop rebuilt or re-validated a broken image indefinitely up to its
deadline. `run-build-job.sh` now caps build retries per version (`IMOGEN_BUILD_MAX_ATTEMPTS`, default 3,
tracked in the Job's `imogen.build/attempt` annotation) and, past the cap, leaves the Job Failed instead
of recreating it; `validate-image.sh` caps validation retries the same way (`IMOGEN_VALIDATE_MAX_ATTEMPTS`,
default 3) and refuses fast before booting a node. A capped item keeps reporting Failed so the agent
surfaces it for a human via `notify` rather than spinning on it. (The earlier "timeout not enforced" was a
misread: the stress-test CronJob deliberately set a 12h `IMOGEN_RECONCILE_TIMEOUT`, so the long run was
within budget, not a runaway.)

Scaling and footprint. Two refinements were evaluated for how the builder cluster scales and
how small the idle footprint can get.

1. cluster-autoscaler for the builder pool (done). The Cluster API autoscaler provider scales the
   `AzureMachinePool` 0↔N from unschedulable pods, so the agent just submits the build Job and the
   cluster right-sizes itself, then scales back to zero after the idle delay. This replaces both the
   imperative scale-up in `run-build-job.sh` and the proposed `scale-builder-pool` tool. The autoscaler
   (`deploy/cluster-autoscaler.yaml`) runs on the management cluster where the CAPI objects live and
   watches the builder workload cluster through its CAPI admin kubeconfig secret;
   `hack/setup-builder-cluster.sh` deploys it and annotates the pool for scale-from-zero
   (`capacity.cluster-autoscaler.kubernetes.io/{cpu,memory}` from the node SKU alongside
   `cluster-api-autoscaler-node-group-{min,max}-size`). The build Job requests CPU and memory and is
   marked `safe-to-evict: "false"` so a running build is never interrupted. Verified live on the v1.36.1
   builder: a pending pod scaled the pool 0→1 and it dropped back to 0 after the idle window. Validation
   uses a one-replica MachineDeployment, so it does not need autoscaling.

2. clusterctl pivot to a self-managed builder cluster, then delete AKS (considered, deferred). Moving
   the CAPI objects into the builder cluster with `clusterctl move` and tearing down AKS is a real,
   supported pattern, but it is deferred. AKS gives a free managed control plane, while a self-managed
   CAPZ cluster must run its own control-plane VM 24/7 and own etcd backups, certs, and CP upgrades, so
   the idle cost is not clearly lower. It also worsens reconstructibility: Azure has reaped the builder
   cluster repeatedly, and with AKS as manager it is rebuildable from scripts, whereas a reaped
   self-managed cluster has no manager left to rebuild it. The tool server, agent, ModelConfig, and
   release-watcher CronJob would also need a new home. The lower-risk way to shrink the idle footprint is
   to keep the cheap AKS management cluster and shrink the builder when idle: cluster-autoscaler scales
   workers to zero (refinement 1), and more aggressively the agent can tear the whole builder cluster
   down after a reconcile and recreate it on demand (about 15 minutes), so when fully idle only the AKS
   management node runs. That also makes a nice agentic demo of the agent provisioning and deprovisioning
   its own build infrastructure.

## Goals (restated)
1. **Functional:** Keep the Community Gallery CAPZ reference images current automatically.
   - Detect new Kubernetes releases not yet in the Community Gallery.
   - Build & publish matching CAPZ reference images (image-builder).
   - Validate images in-cluster before publishing.
   - Remove EOL images; refresh periodically / on-trigger (incl. high-priority base-image CVEs).
2. **Strategic ("Agent Dogfood"):**
   - Learn AI agentic programming / frameworks **running on Kubernetes**.
   - Demonstrate current AI patterns in Azure driven from a Kubernetes cluster.
   - Remove the single-person (Matt) bottleneck and the GitHub-publishing-workflow friction.
   - NOTE: the auto-classification "team/containerd" label is **inaccurate** — re-triage.

## Default supported flavors
Ubuntu 24.04, Ubuntu 26.04, Azure Linux 3, Windows Server 2022, Windows Server 2025.
All are gen1 (gallery definitions V1). Azure Linux 3 will be replaced by Azure Linux 4 once it is
officially released; Azure Linux 4 is gen2 (V2). The unattended release watcher reconciles all five
flavors. Windows validation joins a real Windows worker to the builder cluster (Calico HNS + a
version-matched Windows kube-proxy + the Windows cloud-node-manager) and runs a HostProcess smoke pod.

---

## Verified upstream facts (research, June 2026)

### image-builder (`kubernetes-sigs/image-builder`)
- Released container artifact: `registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.55`
  (staging: `gcr.io/k8s-staging-scl-image-builder/...`). ENTRYPOINT is `make`; pass a target as CMD.
- Reference workflow: `.github/workflows/build-azure-sig.yaml` (`workflow_dispatch` only).
  Pipeline = **build → test (smoke VM) → approve (manual gate) → promote (community gallery)**.
  Azure auth via **OIDC** (`azure/login`), then Packer uses `USE_AZURE_CLI_AUTH=True`.
- Build target naming: `make build-azure-sig-<os>-<ver>`, e.g.:
  - `build-azure-sig-ubuntu-2404`, `build-azure-sig-ubuntu-2604`
  - `build-azure-sig-windows-2022-containerd`, `build-azure-sig-windows-2025-containerd`
  - (gen2 / cvm variants exist; Azure Linux only `azurelinux-3`)
- Targets enumerated in `images/capi/azure_targets.sh`. No `build-azure-vhd-*` targets — SIG/ACG only.
- `init-sig.sh` auto-creates RG + gallery + image definition (nothing pre-required).
- Image version: workflow overrides default `0.3.<ts>` with `--var sig_image_version=<k8s version>`,
  so gallery image version == Kubernetes semver.
- Smoke test in workflow: temp RG + `Standard_D2s_v3` VM from managed image; checks kubelet/kubeadm/
  containerd versions + `kubeadm init --dry-run`; always tears down.
- Promote needs org vars: `EULA_LINK`, `PUBLISHER_EMAIL`, `PUBLISHER_URI`, `SIG_PUBLISHER`.

### CAPZ (`kubernetes-sigs/cluster-api-provider-azure`)
- `AzureMachinePool` (`infrastructure.cluster.x-k8s.io/v1beta1`, `exp/api`) == an Azure **VMSS**.
  `MachinePool` feature gate Beta/on by default since CAPI v1.7.
- **Scale-to-zero:** supported. Autoscaler annotations on MachinePool/MachineDeployment:
  `cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "0"` and `...-max-size: "N"`.
  Scale-**from**-zero is best-documented/tested for **MachineDeployment + AzureMachineTemplate**
  (CAPZ auto-populates `status.capacity`/`status.nodeInfo` from Azure SKU API). For VMSS MachinePools
  it works at infra level but is less battle-tested → MVP may scale imperatively.
- **AKS as management cluster:** explicitly supported & the primary getting-started path.
  Bootstrap: AKS w/ `--enable-oidc-issuer --enable-workload-identity` → UAMI (Contributor) →
  federated cred for `system:serviceaccount:capz-system:capz-manager` → `clusterctl init --infrastructure azure`.
- **Auth:** `AzureClusterIdentity` with `type: WorkloadIdentity` (recommended; env-var creds removed).
- **Custom image reference** (`spec.template.image.computeGallery`):
  community gallery needs only `gallery` + `name` + `version` (no sub/RG). Private gallery needs
  `subscriptionID` + `resourceGroup`.
- **Windows:** supported (containerd 1.6+, K8s 1.23+); VM name ≤15 chars (CAPZ truncates, MachinePool
  prefix `win`); SSH key must be in `KubeadmConfigTemplate users[].sshAuthorizedKeys`, not `sshPublicKey`.

---

## Proposed architecture

```
                 ┌────────────────────────────────────────────────────────┐
                 │ AKS management cluster (control plane, always-on, small) │
                 │                                                          │
                 │  • CAPZ (clusterctl init) + Cluster API                  │
                 │  • Agent control plane (orchestrator + tool services)    │
                 │  • Workload Identity (no secrets) → Azure                │
                 │  • Release-watcher CronJob / agent tool                  │
                 └───────────────┬──────────────────────────────┬─────────┘
                                 │ manages (CAPI)                │ drives
                                 ▼                               ▼
         ┌────────────────────────────────────┐     ┌──────────────────────────┐
         │ CAPZ workload cluster ("builder")   │     │ Azure Compute Gallery     │
         │  • VMSS MachinePool scales 0↔N      │     │  • staging gallery        │
         │  • runs image-builder Job(s)        │────▶│  • community gallery      │
         │  • scale-to-0 when idle             │     └──────────────────────────┘
         │  • validation nodepool from staging │
         │    image (computeGallery ref)       │
         └────────────────────────────────────┘
```

### Components
1. **Trigger sources**
   - *Release watcher:* compares upstream k8s releases (and supported skew) against image
     versions present in the community gallery; emits "build needed" events.
   - *Schedule:* periodic refresh.
   - *CVE feed:* high-priority base-image vuln → rebuild affected flavors (later phase).
2. **Orchestrator agent** (the "agentic" core, runs on AKS mgmt cluster)
   - LLM-driven (Azure OpenAI) tool-calling loop that sequences: decide → build → validate →
     promote → cleanup, with human-approval gate before promote.
   - Tools (each a thin, audited K8s/Azure action): `list-gallery-versions`, `list-k8s-releases`,
     `submit-build-job`, `scale-builder-pool`, `attach-validation-nodepool`, `run-smoke-tests`,
     `promote-image`, `gc-eol-images`, `notify`.
3. **Build executor** — K8s Job on the builder workload cluster running the image-builder container
   with the right `build-azure-sig-<os>-<ver>` target → publishes to **staging** gallery.
4. **Validation** — attach a CAPZ MachinePool/MachineDeployment whose `image.computeGallery` points at
   the staging image version; assert node Ready + version + basic conformance/smoke; tear down.
5. **Promotion** — staging → community gallery (mirror image-builder promote logic / `az sig image-version`).
6. **Cleanup agent** — enforce retention: prune EOL k8s versions and stale image versions per policy.

### Azure auth model
- All cluster→Azure auth via **Workload Identity / UAMI federated credentials** (no stored secrets).
- image-builder Job authenticates via a federated UAMI (replace `USE_AZURE_CLI_AUTH` flow with
  workload-identity token, or `az login --federated-token` inside the Job).

### Agent framework — DECIDED: kagent + Azure OpenAI
**kagent** (CNCF sandbox, `kagent-dev/kagent`) — Kubernetes-native agents-as-CRDs; chosen to
maximize K8s-native agentic learning. Relevant constructs:
- **Controller** — watches/reconciles agent CRDs, spins up agent runtime Pods.
- **Agent** CRD — system prompt + referenced tools + model config.
- **ModelConfig** CRD — abstracts the LLM provider; here **Azure OpenAI** (endpoint + deployment + key/identity).
- **ToolServer** CRD — registers tools over **MCP** (in-cluster or external). Our pipeline actions
  (`list-gallery-versions`, `submit-build-job`, `scale-builder-pool`, `attach-validation-nodepool`,
  `run-smoke-tests`, `promote-image`, `gc-eol-images`, `notify`) become **MCP tools** behind a
  ToolServer. Built-in Kubernetes/Helm/Prometheus tools are reused where useful.
- **A2A** — agent-to-agent RPC, available later for multi-agent role split (build/validate/promote).
- Observability via OpenTelemetry/Prometheus; install via Helm.

Mapping: the "orchestrator agent" = one kagent **Agent** CRD (Azure OpenAI **ModelConfig**) wired to a
**ToolServer** exposing our pipeline as MCP tools. Human-approval gate before `promote-image`.

---

## MVP scope (thin vertical slice)

**Outcome:** one flavor, end-to-end, agent-orchestrated, human-approved promote.

In:
- AKS management cluster + CAPZ (`clusterctl init`), Workload Identity auth.
- One CAPZ "builder" workload cluster with a single VMSS MachinePool; **imperative** scale 0↔N
  (defer autoscaler-from-zero).
- **Ubuntu 24.04 only** (`build-azure-sig-ubuntu-2404`) via image-builder container as a K8s Job →
  staging gallery.
- Validation: attach one Linux MachineDeployment from the staging image (`computeGallery` ref);
  assert Ready + kubelet version + `kubeadm` dry-run-style smoke.
- Promote staging → community gallery on manual approval.
- **Single orchestrator agent** with the tool set above (release-watcher tool may be stubbed to a
  manual "build 1.xx.y" request for MVP) using Azure OpenAI.
  - kagent: install via Helm on the AKS mgmt cluster; one **ModelConfig** (Azure OpenAI), one
    **Agent**, one **ToolServer** exposing pipeline actions as MCP tools.
- Basic observability/audit log of every tool action.

Out (later phases):
- ~~Windows 2022/2025~~ — done (Phase 2): full node-join validation with Calico HNS, a version-matched
  Windows kube-proxy, the Windows cloud-node-manager, and a HostProcess smoke pod.
- ~~Ubuntu 26.04~~ — done. Azure Linux: `azurelinux-3` is live; Azure Linux 4 is deferred until
  image-builder ships it (currently only `azurelinux-3`).
- ~~Autoscaler scale-from-zero for builder pool~~ — done (Phase 2): cluster-autoscaler scales the
  builder MachinePool 0↔N from pending build pods.
- ~~EOL cleanup automation~~ — done: `gc-eol-images` retires whole minors past their upstream EOL
  grace, applied unattended by the release-watcher. CVE-triggered rebuilds — still Phase 3.
- ~~Full release-watcher automation~~ — done: a daily CronJob drives build→validate→promote
  unattended (`IMOGEN_RECONCILE_AUTO_PROMOTE=1`). When a build or validation exhausts its retry cap,
  `list-reconcile-plan` marks the item `blocked` and the plan `stuck`, so the watcher gives up and
  notifies a human (`level=approval`) instead of looping to its deadline. Multi-agent role split and
  self-service triggers — still Phase 3.

### MVP milestones
1. Bootstrap AKS mgmt cluster + CAPZ + Workload Identity; create staging & community galleries.
2. Run image-builder ubuntu-2404 Job → staging gallery (prove auth + publish path).
3. Stand up builder workload cluster; scale 0↔N imperatively.
4. Validation nodepool from staging image + smoke test.
5. Promote to community gallery (manual approval gate).
6. Wrap 1–5 behind the orchestrator agent + tools; demo a single "make 1.xx.y current" run.
   - Build the MCP ToolServer exposing pipeline actions; deploy kagent + ModelConfig + Agent CRDs;
     drive the full build→validate→(approve)→promote run from the agent.

## Open questions / decisions
- ~~Agent framework choice~~ → **DECIDED: kagent + Azure OpenAI.**
- Azure OpenAI model + region; cost guardrails for the agent loop.
- Community gallery: reuse the existing one, or stand up a new dogfood gallery?
- Validation depth for MVP: smoke only vs. a Sonobuoy/conformance subset.
- Where the release-watcher gets "supported k8s versions" (upstream releases vs. an internal policy).

## Phase 3 / backlog

The MVP and Phase 2 are done: the unattended release watcher builds, validates, promotes and retires
all five flavors across the supported minors, secretless. A full ground-zero reprovision-and-reconcile
run passed end to end. The items below are deferred; none blocks running the current pipeline in
production.

### Productionization (to go live in the CNCF subscription)
- **Redeploy everything in the CNCF "Kubernetes Prod" subscription and tenant (decided).** imogen runs
  entirely within one tenant: the management cluster, builder cluster, staging gallery, agent, and the
  published community gallery all live in the CNCF subscription. A cross-tenant split (community gallery
  in the CNCF tenant, everything else in the dev tenant) was considered and rejected as too complex: the
  two accounts are in different Entra tenants (`72f988bf-...` Microsoft corp, `d1aa7522-...` Kubernetes
  prod), and secretless cross-tenant writes would need a federated app registration provisioned inside
  the CNCF tenant (admin approval on both sides), while a stored cross-tenant secret would break the
  no-secrets invariant. Single-tenant keeps the current secretless Workload Identity model intact with no
  gallery-splitting code changes.
- **Cutover mechanics.** The setup scripts are already fully parameterized via `IMOGEN_*` env vars, so
  the move is mostly: authenticate to the CNCF tenant, point `hack/foundation.env` at the CNCF
  subscription and galleries, and re-run `setup-foundation.sh` → `setup-mgmt-cluster.sh` →
  `setup-build-identity.sh` → `setup-builder-cluster.sh` → `setup-openai.sh` → `setup-kagent-aks.sh`.
  Reaper protection is already wired for that environment (foundation RG tag, builder RG tag via CAPZ
  additionalTags, AKS node RG lockdown; `pkr-*` temp RGs left reapable).
- **Prerequisites in the CNCF tenant.** Enough subscription rights to create the resource group,
  galleries, user-assigned identities and their role assignments (Contributor on the imogen RG,
  Cognitive Services OpenAI User, Managed Identity Operator), an AKS cluster with OIDC issuer +
  workload identity, and an Azure OpenAI account with sufficient quota. Confirm these with the CNCF
  infra admins before the cutover.
- **Promote publisher metadata.** image-builder's community-gallery promote needs org vars
  (`EULA_LINK`, `PUBLISHER_EMAIL`, `PUBLISHER_URI`, `SIG_PUBLISHER`); set these for the real publisher.

### Deferred features
- **Cost guardrails for the agent loop.** Deferred: ongoing cost is manageable as long as the
  cluster-autoscaler scales the builder pool to zero when idle (only the small AKS management node runs
  when fully idle). Revisit if the agent loop's Azure OpenAI spend becomes a concern.
- **CVE-triggered rebuilds.** A high-priority base-image CVE feed that rebuilds affected flavors out of
  band, not only on new Kubernetes patch releases.
- **Deeper validation.** Beyond the current Ready + kubelet version + containerd + HostProcess/host
  smoke pod, add a Sonobuoy or conformance subset.
- **Multi-agent role split (A2A).** Separate build/validate/promote agents instead of the single
  orchestrator, using kagent agent-to-agent RPC.
- **Self-service triggers.** An on-demand "make 1.xx.y current" request path in addition to the daily
  release-watcher CronJob.

### Blocked upstream
- **Azure Linux 4 (gen2, V2 image definitions).** Waiting on image-builder to ship an `azurelinux-4`
  target; it replaces `azurelinux-3` and needs a hyper-v-generation V2 gallery definition.
- **Remove the runtime jq sysprep patch** in `deploy/build-job.yaml` once an image-builder release
  includes the merged Windows admin/password fix (PR #2117, not in v0.1.55).

### Operational nice-to-haves
- **`ttlSecondsAfterFinished` on build Jobs** so `Complete` build Jobs auto-clear on the builder
  cluster instead of lingering.
- **Re-triage the inaccurate "team/containerd" auto-classification label** on the source issue.
