# AGENTS.md

Guidance for humans and AI agents working in the **imogen** repository.

## What this project is

imogen is an **agentic system** that keeps Kubernetes node *reference images* in Azure
current. It detects new Kubernetes releases, builds matching CAPZ reference images with
[image-builder](https://github.com/kubernetes-sigs/image-builder), validates them in a live
cluster, publishes them to an Azure Community Gallery, and retires end-of-life images.

A second, equal goal is to **dogfood agentic AI on Kubernetes**: learn Kubernetes-native agent
frameworks and demonstrate current Azure AI patterns driven from a cluster.

See [docs/plan.md](docs/plan.md) for the full design and the MVP scope. Keep that document and
this one in sync as the system evolves.

## Architecture at a glance

- **AKS management cluster** — always-on control plane. Hosts CAPZ (`clusterctl init`), the
  agent control plane (kagent), and triggers (release watcher). Authenticates to Azure via
  **Workload Identity** (no stored secrets).
- **CAPZ "builder" workload cluster** — a VMSS-backed `AzureMachinePool` that scales 0↔N. Runs
  image-builder Jobs and hosts a validation nodepool booted from the staging image.
- **Azure Compute Gallery** — staging gallery (pre-validation) → community gallery (published).

### Agent layer: kagent + Azure OpenAI

The orchestrator is a [kagent](https://github.com/kagent-dev/kagent) **Agent** CRD wired to an
Azure OpenAI **ModelConfig** and a **ToolServer** that exposes the pipeline as **MCP** tools.

Pipeline (build → validate → promote → cleanup), with a human-approval gate before promote:

| Tool (MCP)                  | Action |
|-----------------------------|--------|
| `list-k8s-releases`         | Enumerate upstream Kubernetes releases in scope |
| `list-reconcile-plan`       | Diff in-scope releases against both galleries per flavor; return the exact work list (build vs validate-promote) |
| `list-gallery-versions`     | List image versions already in the community gallery |
| `submit-build-job`          | Run image-builder (`build-azure-sig-<os>-<ver>`) → staging gallery |
| `get-build-status`          | Report a build container's state (Running/Succeeded/Failed) |
| `scale-builder-pool`        | Scale the CAPZ builder MachinePool 0↔N |
| `validate-image`            | Start booting a node from a staging image (`image.computeGallery`), assert Ready + version + smoke checks; returns immediately |
| `get-validation-status`     | Report a validation's state (Running/Succeeded/Failed/NotFound) |
| `promote-image`             | Start promoting staging → community gallery (after approval); returns immediately. `replace=true` rebuilds an existing community version in place |
| `get-promote-status`        | Report a promotion's state in the community gallery (Creating/Succeeded/Failed) |
| `gc-eol-images`             | Report (dry run) or delete image versions whose minor is past its upstream EOL grace; `apply=true` to delete |
| `get-audit-log`            | Return the most recent tool actions (tool, input, outcome, error, duration) for reporting and diagnosis |
| `notify`                    | Push a status update or approval request to a configured Slack/Teams webhook (log-only when unset) |

## Supported image flavors (default)

Ubuntu 24.04, Ubuntu 26.04, Azure Linux 3, Windows Server 2022, Windows Server 2025. image-builder
Azure targets follow `build-azure-sig-<os>-<ver>`, and every target here builds gen1, so the gallery
image definitions are hyper-v-generation V1. The version variable is OS-specific: Ubuntu pins
`kubernetes_deb_version` (patch plus package revision), Azure Linux pins `kubernetes_rpm_version`
(plain patch), and Windows downloads binaries by semver and needs neither; `hack/run-build-job.sh`
selects the right one per flavor. Azure Linux 3 is gen1; when Azure Linux 4 is officially released it
replaces 3 and is gen2 (definitions would be V2). The release watcher only builds the Linux flavors
today (`ubuntu-2404 ubuntu-2604 azurelinux-3`); Windows validation is still a manual fork, so the two
Windows flavors are defined and buildable but not yet in the unattended watcher scope.

## Key upstream facts to respect

- image-builder ships a container: `registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64`
  (ENTRYPOINT is `make`; pass the build target as the command). Reference pipeline lives in its
  `.github/workflows/build-azure-sig.yaml` (build → test → approve → promote, OIDC auth).
- CAPZ `AzureMachinePool` == an Azure VMSS; scale-to-zero is supported via cluster-autoscaler
  annotations (`cluster.x-k8s.io/cluster-api-autoscaler-node-group-{min,max}-size`).
- CAPZ recommends `AzureClusterIdentity` with `type: WorkloadIdentity`; AKS-as-management-cluster
  is the documented primary path.
- Reference a gallery image via `spec.template.image.computeGallery` (community galleries need
  only `gallery` + `name` + `version`).
- Windows nodes: containerd 1.6+, K8s 1.23+, VM name ≤15 chars, SSH key goes in
  `KubeadmConfigTemplate users[].sshAuthorizedKeys` (not `sshPublicKey`).

## Conventions for contributors and agents

- **Keep docs current.** Update `AGENTS.md`, `README.md`, and `docs/plan.md` in the same change
  whenever architecture, scope, layout, or commands change. Don't let docs drift from code.
- **No secrets in the repo or in commits.** All Azure auth is Workload Identity / federated
  credentials.
- **Prefer ecosystem tooling** (Helm, clusterctl, az, kubectl, image-builder make targets) over
  bespoke reimplementations.
- **Human-approval gate** stays in front of `promote-image` for interactive runs. The unattended
  release-watcher is the one explicitly-automated exception: it auto-promotes validated images
  (`IMOGEN_RECONCILE_AUTO_PROMOTE=1`). Retirement (`gc-eol-images apply=true`) is never automated.
- Commit messages: single line; no `Co-authored-by` trailer.

## Repository layout

```
.
├── AGENTS.md            # this guide
├── CODE_OF_CONDUCT.md   # Microsoft Open Source Code of Conduct
├── CONTRIBUTING.md      # how to contribute (CLA)
├── Dockerfile           # builds the tool server image
├── LICENSE              # Apache 2.0
├── Makefile             # build, test, run targets
├── NOTICE               # attribution notice
├── README.md            # project overview
├── SECURITY.md          # how to report security issues
├── assets/              # static assets (project image + attribution)
├── cmd/
│   └── imogen-toolserver/  # MCP tool server entrypoint
├── deploy/              # kagent manifests + CAPZ builder cluster addons (Calico, identity),
│                        #   build Job, release-watcher CronJob
├── docs/
│   └── plan.md          # design & MVP plan
├── hack/                # operational scripts (Azure foundation, build, openai, kagent)
└── internal/
    ├── azure/           # az CLI wrappers
    ├── k8s/             # upstream Kubernetes release lookups
    └── tools/           # MCP tool implementations
```

Code is Go. The MCP tool server lives in `cmd/imogen-toolserver`; tools are added in
`internal/tools`. Build and test with `make build` and `make test`; run the server locally with
`make run`.

### Observability and audit log

Every tool call is audited. `internal/tools/audit.go` wraps each tool with `auditedTool` (a drop-in
for `mcp.AddTool`) so that on every call it records the tool name, the input arguments, success or
failure, the error, and the duration. Each event is emitted to stderr as a structured JSON line, so
it lands in the pod logs and flows to Azure Monitor like any other container log. stderr is used
rather than stdout so audit output never corrupts the stdio MCP transport in local runs. The same
events are also kept in an in-memory ring buffer (size `IMOGEN_AUDIT_BUFFER_SIZE`, default 200),
which the `get-audit-log` tool reads back so the agent can report what the system has been doing or
diagnose a failed run without leaving the conversation. `get-audit-log` is itself unaudited, so
reading the log does not flood it.

From a workstation, `hack/audit-log.sh` reads that same log without going through the agent: it
port-forwards to the toolserver Service, speaks enough MCP to call `get-audit-log`, and prints the
actions newest last. `--tool <name>` filters to one tool, `--changes` shows only the actions that
create or delete a published community-gallery image (`promote-image`, `gc-eol-images`) and flags
them, `--watch` follows new actions live, and `--json` emits the raw events. The in-memory log resets
when the toolserver pod restarts, so for durable history read the container logs
(`kubectl -n kagent logs deploy/imogen-toolserver`) or Azure Monitor, where the same JSON lines land.

### Notifications (notify)

The `notify` tool pushes a status update or approval request out to a human channel, so the
unattended release watcher's progress and its approval requests are visible when no one is watching
the A2A stream. When `IMOGEN_NOTIFY_WEBHOOK_URL` is set, notify POSTs the message to that webhook;
when it is unset, notify falls back to the log only (the message is still captured in the audit log,
since notify is audited). It sends the payload shape the destination expects: Slack incoming webhooks
take `{"text": ...}`, while Microsoft Teams Workflows webhooks (the replacement for the retired
Office 365 connectors) take a `message` envelope wrapping an Adaptive Card. notify infers the shape
from the webhook host (Teams for `office.com` / `powerplatform.com` / `logic.azure.com`, Slack
otherwise); `IMOGEN_NOTIFY_FORMAT` (`slack` or `teams`) forces it. The webhook URL is injected from
the optional `imogen-notify` Secret (`webhook-url` key) in `deploy/toolserver-aks.yaml`, so it stays
out of the repo. notify never gates the pipeline: the real approval gate stays in the agent's system
message, `level=approval` only surfaces the request, and a delivery failure is reported
(`delivered=false`) but never fatal. The release watcher's reconcile prompt ends every run with a
`notify` summary and raises a `level=approval` notification when a human is needed.

### Azure foundation

`hack/setup-foundation.sh` creates the resource group, staging and community galleries, and the
per-flavor image definitions. Everything is parameterized via `IMOGEN_*` env vars (see
`hack/foundation.env.example`) so the dev galleries in a personal subscription can be swapped for
the production galleries in the CNCF subscription. `hack/teardown-foundation.sh` removes them.

### Image build

`hack/setup-build-identity.sh` creates the user-assigned managed identity the build authenticates
with, granting it Contributor on the subscription so Packer can create the temporary build VM.
`hack/run-build-job.sh <flavor> <version>` runs the image-builder container as a Kubernetes Job on
the CAPZ builder cluster, publishing to the staging gallery. The Job pod authenticates with the
build identity exposed on the builder VMSS through IMDS (no stored secret), so the build identity is
assigned to the worker VMSS by `hack/setup-builder-cluster.sh`. The Job pod requests CPU and memory,
so when the builder pool is at zero the pod stays Pending and cluster-autoscaler scales the pool up
to give it a node; the autoscaler scales back to zero once the build finishes (see Builder cluster
below). `hack/run-build-job.sh` applies `deploy/build-job.yaml` and returns immediately with the
Job name. A Job spec is immutable, so it force-recreates (`kubectl replace --force`) any prior Job of
the same name, which lets a failed build be retried and an existing version be rebuilt without a manual
cleanup step. `hack/build-status.sh <job>` reports the Job state (Pending, Running, Succeeded, Failed or
NotFound). The `submit-build-job` and `get-build-status` MCP tools wrap the same two scripts.

`run-build-job.sh` passes `kubernetes_deb_version` to image-builder for Ubuntu flavors, which installs
it verbatim (`kubelet={{ kubernetes_deb_version }}`), so the value must match a real published package.
The Debian revision is usually `-1.1`, but the release team occasionally rebuilds a patch's packages
and bumps it (1.36.2 shipped as `-2.1`), so `imogen_k8s_deb_version` in `hack/lib.sh` looks the revision
up from the community apt repo (`pkgs.k8s.io`) instead of assuming `-1.1`. The lookup retries a few
times to ride out a transient network blip, then fails (non-zero) so `run-build-job.sh` aborts with a
clear message rather than guessing a revision that would only break the build minutes later. Azure Linux
uses `kubernetes_rpm_version` (plain patch, no revision) and Windows needs no package variable, so this
lookup runs only for `ubuntu-*`.

Packer builds in a temporary resource group it creates and, on success or a graceful failure,
deletes itself. A hard failure (the pod killed, the node deallocated, an activeDeadline timeout) can
kill Packer before it cleans up, leaking that group. To clean those up safely in this shared
subscription, the build Job tags Packer's `azure_tags` with an `imogen-build` marker (a `jq` patch of
`packer.json` before `make`), and `hack/gc-build-rgs.sh` deletes only groups that carry that marker,
are named like a Packer temp group, and are older than `IMOGEN_BUILD_RG_TTL` (default 3h, well beyond
any real build) so a running build is never touched. It defaults to a dry run; `--apply` (or
`IMOGEN_BUILD_RG_APPLY=1`) deletes. `hack/run-build-job.sh` runs the sweep with `--apply` before each
build, so a leak from one run is collected on the next.

### Image promotion

`hack/promote-image.sh <flavor> <version> [--replace]` copies a validated image version from the
staging gallery to the community gallery, sourced from the staging version (both galleries live in
the same resource group). It blocks until the copy finishes, which suits a human running it directly.
The `promote-image` MCP tool does the same copy but submits it with `az --no-wait` and returns
immediately, because the gallery create can run for several minutes and a blocking tool call would
trip the MCP client's timeout (the agent would then narrate a timeout as success). The agent polls
`get-promote-status`, which reports the community version's provisioningState (Creating, Succeeded,
Failed or NotFound), until it is Succeeded. Both run only after validation passes and approval is
granted.

Gallery image versions are immutable, so rebuilding a version that already exists in the community
gallery means deleting it and recreating it from staging. Passing `--replace` to the script (or
`replace=true` to the tool) does exactly that: it deletes the existing community version first, then
recreates it from the validated staging version. There is a brief window where the version is absent
from the community gallery, so this only happens on explicit request, never in the release watcher.

### Image retirement (garbage collection)

`hack/gc-eol-images.sh [flavor] [--apply]` retires image versions whose Kubernetes minor has been
out of upstream support for longer than a grace period. The policy is deliberately conservative:
downstream projects (cloud-provider-azure, cluster-autoscaler) keep testing against out-of-support
releases and pin specific patches, so it retires whole minors only, never individual patches, and
only once a minor is past its upstream end-of-life date by `IMOGEN_GC_GRACE_DAYS` (default 365). A
minor still supported, within the grace window, or with no known EOL date is always kept. Per-minor
EOL dates come from endoflife.date (`IMOGEN_K8S_EOL_URL`). It defaults to a dry run that only lists
the candidates, and deletes only with `--apply` (or `IMOGEN_GC_APPLY=1`). `IMOGEN_GC_STAGE` picks
the staging or community gallery (default community). The `gc-eol-images` MCP tool applies the same
policy (with a `graceDays` input) and returns the candidates; `apply=true` deletes them. Retirement
is destructive, so the agent runs a dry run first and asks for approval before applying, and the
release-watcher only ever reports candidates.

### Image validation

`hack/validate-image.sh <flavor> <version>` boots one node from a staging gallery image on the
builder cluster and checks it. It attaches a one-node MachineDeployment whose
`image.computeGallery` points at the staging version (`deploy/validation-machinedeployment.yaml`),
waits for the node to be Ready, asserts the kubelet version matches and the runtime is containerd,
then runs a `hostNetwork` smoke pod. The pod uses host networking so it does not wait on Calico
initializing on the fresh node. The validation node is annotated to skip drain on teardown so a
node without working CNI does not block deletion. Everything is torn down on exit unless
`IMOGEN_VALIDATE_KEEP=1` is set. The script replicates the staging image to the builder region
(`IMOGEN_BUILDER_LOCATION`) first if needed, since builds publish only to the gallery home region.

A full validation takes several minutes, which is longer than the MCP client timeout, so the
`validate-image` tool does not run the script inline. Like `submit-build-job` and `promote-image`, it
starts the script in the background and returns immediately; the agent then polls `get-validation-status`
until the state is Succeeded or Failed. The background run writes its output to a log file and its exit
code to a done file under `IMOGEN_VALIDATE_STATE_DIR` (default the system temp dir), keyed by flavor and
version, and `get-validation-status` reads those back. Re-calling `validate-image` for a run already in
flight reports Running rather than starting a second one.

The validation node runs the image's Kubernetes version, so the builder cluster's control plane must
be at least that minor: a kubelet may run up to two minors behind the kube-apiserver but never ahead.
The builder control plane therefore tracks the newest in-scope minor (`IMOGEN_BUILDER_K8S_VERSION`,
default a 1.36 CAPI reference image), which lets a single cluster validate that minor and the
supported older ones. CAPI's MachineSet preflight checks still block a worker whose minor differs from
the control plane (the normal mid-upgrade state), so the validation MachineDeployment carries the
`machineset.cluster.x-k8s.io/skip-preflight-checks: "KubeadmVersionSkew,KubernetesVersionSkew"`
annotation, which CAPI propagates to the generated MachineSet. The smoke pod runs on the builder
cluster in the `default` namespace (`IMOGEN_VALIDATE_POD_NAMESPACE`); pinning it matters in cluster,
where kubectl would otherwise inherit the tool server pod's `kagent` namespace.

### Builder cluster (CAPZ)

The durable home for builds and validation is a Cluster API (CAPZ) setup, all authenticated with
workload identity so there are no stored secrets.

`hack/setup-mgmt-cluster.sh` creates an AKS management cluster with the OIDC issuer and workload
identity enabled, a user-assigned identity (`imogen-capz`) with Contributor on the subscription,
federated credentials for the `capz-manager` and `azureserviceoperator-default` service accounts,
then runs `clusterctl init` (with `EXP_MACHINE_POOL=true`) and applies the `AzureClusterIdentity`
from `deploy/azure-cluster-identity.yaml`. The AKS OIDC issuer changes whenever the cluster is
recreated, so the script refreshes its federated credentials when the issuer no longer matches,
which keeps CAPZ workload-identity auth working across rebuilds.

`hack/setup-builder-cluster.sh` generates a self-managed "builder" workload cluster with one VMSS
MachinePool (`clusterctl generate cluster --flavor machinepool`), then installs Calico
(`deploy/calico-values.yaml`) and the external Azure cloud provider so the nodes become Ready. The
builder runs in `IMOGEN_BUILDER_LOCATION` (falling back to the mgmt region, then the gallery region),
so it can sit in a different region from the management cluster. That matters because the CAPI
community-gallery reference image must be replicated to the builder region, and capacity-constrained
regions may not carry every version, so the builder lands where the chosen `IMOGEN_BUILDER_K8S_VERSION`
image actually exists. VM sizes are configurable (`IMOGEN_BUILDER_CP_SIZE`, `IMOGEN_BUILDER_NODE_SIZE`)
and default to broadly available v2 sizes; the script fails fast via `hack/lib.sh` `imogen_require_sku`
if a size is not offered in the region, sets bounded node drain/detach timeouts so teardown is not
blocked by deallocated nodes, and waits for the expected worker count. It also assigns the build
managed identity to the worker VMSS so image-builder Jobs can authenticate through IMDS. The control
plane boots from the CAPI community-gallery reference image for `IMOGEN_BUILDER_K8S_VERSION`, so that
version must match a reference image replicated to the builder region and should be the newest
in-scope minor (see Image validation above). The builder cluster is ephemeral, so to move it to a
newer minor recreate it (`teardown-builder.sh` then `setup-builder-cluster.sh`) rather than upgrading
in place, since a control-plane upgrade can only step one minor at a time.

`hack/setup-builder-cluster.sh` also deploys cluster-autoscaler (`deploy/cluster-autoscaler.yaml`)
onto the management cluster. It runs the Cluster API provider against the in-cluster CAPI objects
and watches the builder workload cluster through the CAPI-generated admin kubeconfig secret, scaling
`${CLUSTER}-mp-0` between 0 and `IMOGEN_BUILDER_MAX_NODES` (default 3) from pending pods. The pool is
annotated for scale-from-zero (`cluster-api-autoscaler-node-group-{min,max}-size` plus
`capacity.cluster-autoscaler.kubernetes.io/{cpu,memory}` derived from the node SKU). A pending build
Job pod triggers a scale-up, and the pool drops back to 0 after about five idle minutes; build Job
pods carry `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` so a running build is never
interrupted. `hack/scale-builder.sh <count>` still scales the pool imperatively as a manual override.
`hack/teardown-builder.sh` removes the autoscaler, then deletes the workload cluster, and with
`--mgmt` the AKS cluster too. It
waits a bounded time for graceful deletion, then forces cleanup (deleting the workload resource group
and clearing leftover CAPI finalizers) so a cluster whose nodes Azure already deallocated still tears
down cleanly.

Image-builder runs as a Kubernetes Job on this builder cluster (`deploy/build-job.yaml`), authenticated
with the build managed identity through IMDS.

### Running the agent (kagent)

The agent layer is kagent driving the tool server over MCP. The tool server speaks MCP over
stdio by default, or over streamable HTTP when `IMOGEN_TOOLSERVER_ADDR` is set, which is how it
runs in cluster.

Local development uses a kind cluster (podman works with `KIND_EXPERIMENTAL_PROVIDER=podman`):

1. `helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` and
   `helm install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent` into the `kagent` namespace.
2. `hack/setup-openai.sh` creates the Azure OpenAI account and model deployment.
3. `hack/setup-kagent.sh` builds and loads the tool server image and applies `deploy/`.

`deploy/` holds the kagent `Agent`, the Azure OpenAI `ModelConfig`, the `RemoteMCPServer`
pointing at the tool server, and the tool server `Deployment` and `Service`.
`hack/teardown-kagent.sh` removes these resources; pass `--cluster` to also delete the kind
cluster.

Auth note: this subscription disallows API-key auth on Azure OpenAI, and this kagent version's
Azure client only sends the api-key header. So the `ModelConfig` carries a short lived Entra ID
Bearer token as a default header, injected by `hack/setup-kagent.sh` and refreshed by rerunning
it. On AKS this is replaced by workload identity.

The tool server image bundles `az` and `kubectl`, but on kind there is no workload identity to
authenticate `az`, so only the network-only `list-k8s-releases` tool works there. To exercise the
full pipeline from the agent locally, run the tool server on the host instead, where it has your
`az` login and the management cluster kubeconfig:

1. `kubectl -n kagent patch remotemcpserver imogen-toolserver --type merge -p '{"spec":{"url":"http://host.containers.internal:8080/"}}'`
2. `hack/run-toolserver-host.sh` (builds and serves the tool server on the host)
3. Restart the agent so it rediscovers the tools: `kubectl -n kagent rollout restart deploy/imogen`

The agent in kind reaches the host through `host.containers.internal`. The tool server sets
`IMOGEN_TOOLSERVER_ALLOW_REMOTE_HOST=1` so its DNS-rebinding protection allows that Host header.
This host path is for the local demo; the durable home is the tool server in the AKS cluster with
workload identity.

#### In AKS with workload identity

`hack/setup-kagent-aks.sh` is the durable path: it deploys kagent and the tool server into the AKS
management cluster so the Azure-backed tools run in cluster with no secrets and no host hack. It
builds and pushes the tool server image with `az acr build` (cloud side, so no local cross-arch
build), creates the `imogen-toolserver` user-assigned identity, grants it the roles it needs on the
`imogen` resource group (Contributor for galleries and builds, Cognitive Services OpenAI User for
the model, Managed Identity Operator on the build identity), and federates it to the
`imogen-toolserver` and `imogen-aoai-refresher` service accounts (refreshing those federated
credentials too when an AKS rebuild changes the OIDC issuer). It installs kagent with the bundled
sample agents and demo MCP servers disabled, since imogen only needs its own agent and tool server
and the samples would otherwise saturate CPU on the small management cluster. The tool server runs as
that identity (`azure.workload.identity/use` pod label) and reads its config from the `imogen-config`
ConfigMap; `deploy/toolserver-rbac.yaml` gives it the cluster permissions to read the builder
kubeconfig secret and drive the CAPI validation objects. `validate-image.sh` detects in-cluster
mode (`IMOGEN_IN_CLUSTER=1`) and reads the builder kubeconfig from its secret instead of clusterctl.

Because this kagent version still only sends the api-key header to Azure OpenAI, the agent keeps
using a short lived Entra token on the `ModelConfig`. That token is valid for about 24 hours, so in
AKS a `imogen-aoai-refresher` CronJob (the same image, workload identity) mints a fresh one once a
day at 07:00, an hour before the release watcher runs, patches it into the `ModelConfig`, and
restarts the agent so it loads the new token. The agent caches the token at startup and does not
re-read the `ModelConfig` live, so the restart is the only way to pick up a new token. A restart
kills any in-flight agent turn, and a full reconcile runs far longer than the old 30-minute cadence,
so the refresh now skips the restart whenever a release-watcher run is active: the running agent
keeps its still-valid token and the next day's refresh restarts it. A kagent A2A turn runs
server-side and survives an SSE client disconnect, so a dropped reconcile stream was never the
cause of a stalled run; the mid-run agent restart was.

The pipeline runs build, then validate, then promote. The agent validates a staging image before
promoting and asks for approval before it promotes. For a hard gate, kagent supports
`requireApproval` on the agent's MCP tool list to pause for human confirmation on named tools such
as `promote-image`.

#### Release watcher (autonomous trigger)

`deploy/release-watcher.yaml` is a daily CronJob (`imogen-release-watcher`, same tool server image)
that runs `hack/reconcile.sh`. The script is thin on purpose: it posts a standing reconcile prompt
to the agent's A2A endpoint over JSON-RPC `message/stream` and lets the agent do the work. The agent
calls `list-reconcile-plan`, which does the per-flavor gap analysis deterministically in Go (it diffs
the in-scope upstream releases against both galleries and returns an explicit work list of `build` and
`validate-promote` items), then drives `submit-build-job` → `get-build-status` → `validate-image` →
`get-validation-status` → `promote-image` → `get-promote-status` for each item. The gap analysis lives
in the tool rather than the model because the model reliably mis-computed the set difference once more
than one flavor was in scope (it would list the galleries correctly, then declare everything present
and do nothing). The watcher runs unattended: because no human is present,
the reconcile prompt authorizes the agent to promote a validated image without approval
(`IMOGEN_RECONCILE_AUTO_PROMOTE=1`). Interactive runs through the kagent UI still hit the approval
gate in the agent's system message, and `gc-eol-images` is only ever a dry run here. Because kagent
runs the task server-side and a single SSE stream can drop while a long build runs, the script does
not depend on one stream: when the stream ends before the task reaches a terminal state it
resubscribes (`tasks/resubscribe`) to the same task and keeps following it, until the task completes
or `IMOGEN_RECONCILE_TIMEOUT` (default 5400s) passes. Other tunables are env vars on the CronJob:
`IMOGEN_RECONCILE_FLAVORS`, `IMOGEN_RECONCILE_MINORS`, `IMOGEN_RECONCILE_MAX`,
`IMOGEN_RECONCILE_AUTO_PROMOTE`.

While a build, validation or promotion is in flight the agent polls its status tool in a tight loop,
and each poll is a full LLM turn that resends the growing conversation. Left unthrottled that loop can
exhaust the Azure OpenAI deployment's tokens-per-minute quota and fail the run with a 429. The model
cannot pace itself (it has no way to sleep and just calls again immediately), so the pacing lives in
the tools: `get-build-status`, `get-validation-status` and `get-promote-status` each block for
`IMOGEN_POLL_DELAY_SECONDS` (default 15, and well under the MCP client timeout) before returning, which
caps the loop rate deterministically. Set it to 0 to disable.

The mgmt-side CAPI objects (the builder `MachinePool`, validation `MachineDeployment`) live in the
`default` namespace, so `run-build-job.sh` and `validate-image.sh` name that namespace explicitly
(`IMOGEN_CAPI_NAMESPACE`, default `default`). The tool server pod's own namespace is `kagent`, so
omitting it makes those `kubectl` calls silently target the wrong namespace.
