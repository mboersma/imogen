# imogen

A system to build, publish, and curate Kubernetes node "reference images" in Azure.

<p align="center">
  <img src="assets/imogen.jpg" alt="Imogen, by Herbert Gustave Schmalz" width="240">
</p>

<p align="center">
  <sub>
    <em>Imogen</em> (c. 1888) by Herbert Gustave Schmalz, depicting the heroine of
    Shakespeare's <em>Cymbeline</em>. Public domain, via
    <a href="https://commons.wikimedia.org/wiki/File:Imogen_-_Herbert_Gustave_Schmalz.jpg">Wikimedia Commons</a>.
  </sub>
</p>

## Features

- Finds current Kubernetes releases without corresponding images in a Community Gallery
- Builds missing images for desired operating systems and distros in a Shared Image Gallery (staging)
- Validates the staging images by bringing them up as nodes in a live Kubernetes cluster
- Publishes validated images to the Community Gallery
- Deletes old, unsupported images from the Community Gallery

## Project layout

- `cmd/imogen-toolserver` — the MCP tool server the agent calls
- `internal/tools` — MCP tool implementations
- `internal/azure` — az CLI wrappers
- `internal/k8s` — upstream Kubernetes release lookups
- `deploy/` — kagent manifests (Agent, ModelConfig, RemoteMCPServer, tool server)
- `hack/` — operational scripts (Azure foundation, image build, Azure OpenAI, kagent)
- `docs/plan.md` — design and MVP plan
- `docs/ai-stack.md` — overview of the AI and agentic technologies used

## Getting started

You need Go 1.26+. Build and test:

```sh
make build
make test
```

Run the tool server locally over stdio:

```sh
make run
```

To create the Azure galleries the pipeline publishes into, configure `IMOGEN_*` env vars
(see `hack/foundation.env.example`) and run `hack/setup-foundation.sh`.

To build a reference image, create the build identity once with `hack/setup-build-identity.sh`,
then run `hack/run-build-job.sh <flavor> <version>`, for example
`hack/run-build-job.sh ubuntu-2404 v1.34.9`. The build runs as a Kubernetes Job on the CAPZ builder
cluster and publishes to the staging gallery; check its progress with `hack/build-status.sh <job>`.

Once an image is validated, promote it to the community gallery with
`hack/promote-image.sh <flavor> <version>`.

To run the agent on a local kind cluster, install kagent, create the Azure OpenAI resource with
`hack/setup-openai.sh`, then run `hack/setup-kagent.sh` to build the tool server image and apply
the manifests in `deploy/`. To drive the full build, validate and promote pipeline from the agent
locally, run the tool server on the host with `hack/run-toolserver-host.sh` and point the
`RemoteMCPServer` at it. To deploy the agent and tool server into the AKS management cluster with
workload identity instead, so the Azure-backed tools run in cluster with no secrets, run
`hack/setup-kagent-aks.sh`. See [AGENTS.md](AGENTS.md) for the full steps.

`setup-kagent-aks.sh` also installs a daily release-watcher CronJob (`deploy/release-watcher.yaml`,
`hack/reconcile.sh`) that asks the agent to reconcile the community gallery against upstream
Kubernetes releases and drive any missing versions through the pipeline, pausing for human approval
before it promotes.

To stand up the CAPZ builder cluster, run `hack/setup-mgmt-cluster.sh` (AKS management cluster
plus Cluster API) then `hack/setup-builder-cluster.sh` (the builder workload cluster). Scale the
build pool with `hack/scale-builder.sh <count>` and tear it down with `hack/teardown-builder.sh`.

To validate a staging image, run `hack/validate-image.sh <flavor> <version>`, for example
`hack/validate-image.sh ubuntu-2404 1.34.9`. It boots a node from the image on the builder
cluster, checks the kubelet version and runtime, runs a smoke pod, then tears it down. Windows
flavors (`windows-2022-containerd`, `windows-2025-containerd`) join a real Windows worker using the
builder cluster's Windows networking (Calico HNS + a version-matched kube-proxy + cloud-node-manager)
and run a HostProcess smoke pod.

## Development

The tool server is written in Go using the [MCP Go SDK](https://github.com/modelcontextprotocol/go-sdk).
Each pipeline action is an MCP tool registered in `internal/tools`. See [AGENTS.md](AGENTS.md) for the
architecture and conventions.

## Design

See [docs/plan.md](docs/plan.md) for the design and MVP plan, and
[docs/ai-stack.md](docs/ai-stack.md) for an overview of the AI and agentic
technologies imogen uses.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security issue, see [SECURITY.md](SECURITY.md).

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or
imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those
third-parties' policies.

