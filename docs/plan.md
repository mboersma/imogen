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

In progress:
- Tool `submit-build-job` / `get-build-status`: standalone image-builder container build
  into the staging gallery, run as an Azure Container Instance. **Temporary**: moves to a
  Kubernetes Job on the CAPZ builder cluster later. Auth uses a user-assigned managed
  identity with `az login --identity` + `USE_AZURE_CLI_AUTH=True` (no service principal
  secret). The in-cluster version will use Workload Identity (init-sig.sh federated-token
  mode). Verified end-to-end: an ubuntu-2404 build published `1.34.9` to `imogen_staging`.
  The build pins the real Kubernetes version (semver, series, deb/rpm) so the gallery
  version label matches what is installed.

Next: builder cluster, validation, promotion, kagent wiring, end-to-end demo.

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
Ubuntu 24.04, Ubuntu 26.04, Windows Server 2022, Windows Server 2025.
Add Azure Linux 4 once officially released (image-builder target TBD; today only `azurelinux-3` exists).

---

## Verified upstream facts (research, June 2026)

### image-builder (`kubernetes-sigs/image-builder`)
- Released container artifact: `registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.52`
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
- Windows 2022/2025 (name-length, SSH-in-KubeadmConfig, longer builds) — Phase 2.
- Ubuntu 26.04, Azure Linux 4 — Phase 2/3.
- Autoscaler scale-from-zero for builder pool — Phase 2.
- CVE-triggered rebuilds + EOL cleanup automation — Phase 3.
- Multi-agent role split, self-service triggers, full release-watcher automation — Phase 3.

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
