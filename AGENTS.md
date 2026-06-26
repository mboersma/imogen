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
| `list-gallery-versions`     | List image versions already in the community gallery |
| `submit-build-job`          | Run image-builder (`build-azure-sig-<os>-<ver>`) → staging gallery |
| `get-build-status`          | Report a build container's state (Running/Succeeded/Failed) |
| `scale-builder-pool`        | Scale the CAPZ builder MachinePool 0↔N |
| `attach-validation-nodepool`| Boot a node from a staging image (`image.computeGallery`) |
| `run-smoke-tests`           | Assert node Ready + version + smoke checks |
| `promote-image`             | Promote staging → community gallery (after approval) |
| `gc-eol-images`             | Remove EOL / stale image versions |
| `notify`                    | Emit status / request approval |

## Supported image flavors (default)

Ubuntu 24.04, Ubuntu 26.04, Windows Server 2022, Windows Server 2025.
Azure Linux 4 will be added once it is officially released (image-builder currently ships
`azurelinux-3`). image-builder Azure targets follow `build-azure-sig-<os>-<ver>`.

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
- **Human-approval gate** stays in front of `promote-image` until explicitly automated.
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
├── deploy/              # kagent manifests + CAPZ builder cluster addons (Calico, identity)
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

### Azure foundation

`hack/setup-foundation.sh` creates the resource group, staging and community galleries, and the
per-flavor image definitions. Everything is parameterized via `IMOGEN_*` env vars (see
`hack/foundation.env.example`) so the dev galleries in a personal subscription can be swapped for
the production galleries in the CNCF subscription. `hack/teardown-foundation.sh` removes them.

### Image build (temporary)

`hack/setup-build-identity.sh` creates the user-assigned managed identity the build authenticates
with, granting it Contributor on the subscription so Packer can create the temporary build VM.
`hack/run-build.sh <flavor> <version>` runs the image-builder container on Azure Container
Instances, publishing to the staging gallery. This is a stopgap; the build moves to a Kubernetes
Job on the CAPZ builder cluster with Workload Identity later. The `submit-build-job` and
`get-build-status` MCP tools wrap the same flow.

### Image promotion

`hack/promote-image.sh <flavor> <version>` copies a validated image version from the staging
gallery to the community gallery, sourced from the staging version (both galleries live in the
same resource group). The `promote-image` MCP tool wraps the same flow and is meant to run only
after validation passes and approval is granted.

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

### Builder cluster (CAPZ)

The durable home for builds and validation is a Cluster API (CAPZ) setup, all authenticated with
workload identity so there are no stored secrets.

`hack/setup-mgmt-cluster.sh` creates an AKS management cluster with the OIDC issuer and workload
identity enabled, a user-assigned identity (`imogen-capz`) with Contributor on the subscription,
federated credentials for the `capz-manager` and `azureserviceoperator-default` service accounts,
then runs `clusterctl init` (with `EXP_MACHINE_POOL=true`) and applies the `AzureClusterIdentity`
from `deploy/azure-cluster-identity.yaml`.

`hack/setup-builder-cluster.sh` generates a self-managed "builder" workload cluster with one VMSS
MachinePool (`clusterctl generate cluster --flavor machinepool`), then installs Calico
(`deploy/calico-values.yaml`) and the external Azure cloud provider so the nodes become Ready. VM
sizes are configurable (`IMOGEN_BUILDER_CP_SIZE`, `IMOGEN_BUILDER_NODE_SIZE`) and default to broadly
available v2 sizes; the script fails fast via `hack/lib.sh` `imogen_require_sku` if a size is not
offered in the region, sets bounded node drain/detach timeouts so teardown is not blocked by
deallocated nodes, and waits for the expected worker count.
`hack/scale-builder.sh <count>` scales the pool imperatively, down to 0 when idle.
`hack/teardown-builder.sh` deletes the workload cluster, and with `--mgmt` the AKS cluster too. It
waits a bounded time for graceful deletion, then forces cleanup (deleting the workload resource group
and clearing leftover CAPI finalizers) so a cluster whose nodes Azure already deallocated still tears
down cleanly.

The image-builder run still goes through Azure Container Instances for now; moving it to a Job on
this builder cluster is the next step.

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
`imogen-toolserver` and `imogen-aoai-refresher` service accounts. The tool server runs as that
identity (`azure.workload.identity/use` pod label) and reads its config from the `imogen-config`
ConfigMap; `deploy/toolserver-rbac.yaml` gives it the cluster permissions to read the builder
kubeconfig secret and drive the CAPI validation objects. `validate-image.sh` detects in-cluster
mode (`IMOGEN_IN_CLUSTER=1`) and reads the builder kubeconfig from its secret instead of clusterctl.

Because this kagent version still only sends the api-key header to Azure OpenAI, the agent keeps
using a short lived Entra Bearer token on the `ModelConfig`. In AKS a `imogen-aoai-refresher`
CronJob (the same image, workload identity) mints a fresh token every 30 minutes, patches it into
the `ModelConfig`, and restarts the agent, so there are no manual reruns.

The pipeline runs build, then validate, then promote. The agent validates a staging image before
promoting and asks for approval before it promotes. For a hard gate, kagent supports
`requireApproval` on the agent's MCP tool list to pause for human confirmation on named tools such
as `promote-image`.
