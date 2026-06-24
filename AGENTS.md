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
├── LICENSE              # Apache 2.0
├── Makefile             # build, test, run targets
├── NOTICE               # attribution notice
├── README.md            # project overview
├── SECURITY.md          # how to report security issues
├── assets/              # static assets (project image + attribution)
├── cmd/
│   └── imogen-toolserver/  # MCP tool server entrypoint
├── docs/
│   └── plan.md          # design & MVP plan
├── hack/                # operational scripts (Azure foundation + build runner)
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

Code scaffolding (MCP ToolServer, kagent CRDs, cluster manifests) will be added here and this
section updated as it lands.
