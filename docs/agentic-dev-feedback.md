# Agentic-on-Kubernetes feedback

A side goal of imogen is to get hands-on experience building an agentic solution on
Kubernetes in Azure, so we can find the pain points that customers are likely to hit and make
strategic upstream contributions. This document captures friction we ran into and concrete
improvement ideas, grouped by project. It is a living list; add to it as we go.

## Summary

The two highest-leverage gaps for our use case:

1. **First-class human-in-the-loop approval** in kagent. Promoting a production image needs a real
   approval gate, and today the confirmation handshake is pushed onto each client.
2. **Cloud identity and token lifecycle**. The Azure OpenAI bearer token in the kagent `ModelConfig`
   expires in about an hour and is refreshed by hand, and tools that shell out to `az` need a
   workload-identity story that is not paved.

## kagent

### Human-in-the-loop approval is half-built
`requireApproval` exists on the agent's MCP tool spec, but it pushes the confirmation handshake onto
the A2A client. For the demo we fell back to a soft "ask before promoting" instruction in the system
message, which is not a real gate. A production promote-to-gallery step needs a server-side
pause/resume with the approval prompt surfaced over A2A and a CLI or UI to approve or deny.

- **Idea:** built-in approval gate that pauses the task, emits an approval-request event, and resumes
  on an approve/deny reply, so every client does not reimplement it.

### Driving an agent is under-tooled
There is no terminal-friendly way to hold a conversation with an agent. We hand-wrote a Python A2A
client (`files/a2a.py`) and reverse-engineered the streaming event shapes: `message/stream` SSE,
`status-update` events, `status.message.parts` with `kind:data` and `metadata.kagent_type` of
`function_call` or `function_response`, `kagent_author` to tell input echoes from output, `contextId`
to maintain a conversation, and `tasks/resubscribe` to reconnect to an in-flight task. None of this
was documented; we learned it by inspection.

- **Idea:** a first-party `kagent run` / chat CLI that streams a conversation, renders tool calls and
  responses, and maintains context.
- **Idea:** document the A2A event schema kagent emits, especially the `kagent_type` and
  `kagent_author` metadata and the resubscribe flow.

### Long-running tools are not well supported
`validate-image` boots a real VM and takes six to eight minutes. When the tool's context is cancelled
the process is SIGKILLed, so cleanup traps do not run and we can leak a validation node. There is no
progress streaming while a long tool runs.

- **Idea:** async tool/task semantics with progress events and graceful cancellation (deadline plus a
  termination signal the tool can trap) so a cancelled tool can still clean up.

### Local dev networking is trial-and-error
Running the tool server on the host and reaching it from kagent in kind took real time to work out:
on podman and macOS `host.containers.internal` works but `10.0.2.2` and `gateway.containers.internal`
do not. We also hit an opaque `403 Forbidden: invalid Host header` (see MCP Go SDK below).

- **Idea:** a documented local-dev mode for "agent in kind, tool server on host," including the
  networking gotchas and the host-header flag.

## MCP Go SDK

### DNS-rebinding protection is opaque for the kind-to-host case
The `StreamableHTTPHandler` returns `403 Forbidden: invalid Host header` when a request arrives over a
localhost address with a non-localhost `Host` header, which is exactly the kind-to-host demo case. The
fix is `StreamableHTTPOptions{DisableLocalhostProtection: true}`, but the error message does not point
to it. We gated it behind `IMOGEN_TOOLSERVER_ALLOW_REMOTE_HOST=1`.

- **Idea:** make the 403 message name the option that disables the check, or expose an allowed-hosts
  allowlist that is friendlier than an all-or-nothing flag.

### Tools that shell out need a heavier base image
Our tool server runs from `gcr.io/distroless/static-debian12`, which has no `az`, `kubectl`, or
`clusterctl`. Tools that shell out to cloud CLIs only work when the binary runs on the host. This is
a packaging reality rather than an SDK bug, but the SDK examples lean entirely on in-process,
network-only tools, so the "my tool needs a CLI and cloud credentials" path is unguided.

- **Idea:** a documented pattern (and maybe a sample) for an MCP tool server that bundles cloud CLIs
  and authenticates with a cloud identity.

## Azure OpenAI / Entra

### Bearer token lifecycle in ModelConfig
The kagent `ModelConfig` carries an Entra bearer token for Azure OpenAI that expires in about an hour.
We refresh it by hand: `az account get-access-token --resource https://cognitiveservices.azure.com`,
`sed` it into `deploy/modelconfig.yaml`, then `kubectl rollout restart deploy/imogen`. This is fine
for a demo and untenable for an always-on agent.

- **Idea:** OIDC/workload-identity token sourcing with automatic refresh, so the agent gets short-
  lived tokens without a manual rotation step. This likely spans kagent and how it reads
  `ModelConfig`.

## CAPZ / Cluster API (context, mostly inherent)

These are not agentic-framework issues, but they shaped the design and are worth noting for customers
doing cloud infrastructure from an agent.

- Deleting a validation `MachineDeployment` hangs at `DrainingNode` if the fresh node has no working
  CNI. We annotate `machine.cluster.x-k8s.io/exclude-node-draining: "true"` on the machine template to
  skip drain on teardown.
- The validation MachineDeployment name is fixed, so only one validation can run at a time; concurrent
  runs collide on the immutable `AzureMachineTemplate`.
- Booting a real node for validation takes six to eight minutes, which is what drives the long-running
  tool requirement above.

## Reconstructibility (recovering from Azure reaping a dev environment)

Azure deallocated our testing VMs overnight (cost governance on a dev subscription). We used this as
a real test of whether the environment rebuilds from scripts with no manual fix-ups. It mostly does
not, and the failures are instructive for any customer running agentic infrastructure on a
non-production subscription.

- **The management cluster does not survive deallocation cleanly.** AKS reported the cluster and
  node pool as `Running`/`Succeeded`, but both node VMs were deallocated, so every controller
  (CAPI, CAPZ, cert-manager) sat `Pending` and the CAPI webhook had no endpoints, which made even
  `kubectl delete cluster` fail with `no endpoints available for service "capi-webhook-service"`.
  AKS power state is not a reliable signal that the data plane is up.
- **The deallocated nodes could not be restarted: `SkuNotAvailable`.** `Standard_B2s` (our default
  for both the AKS nodes and the CAPZ control plane) is capacity-restricted in `eastus2`, and the
  subscription further restricts allowed sizes. Recovery required adding a node pool on an available
  SKU (`Standard_B2s_v2`) and deleting the dead pool. A reaped environment is effectively destroyed,
  not paused, if its SKU is constrained. Defaults should prefer broadly available SKUs, and the
  setup scripts should fail fast with the allowed-size list when a size is unavailable.
- **Tearing down a CAPZ cluster whose nodes Azure already deallocated stalls.** `kubectl delete
  cluster --wait` hung because the `AzureMachinePool` waited on its pool Machine's node drain (node
  unreachable) and the control-plane Machine was blocked on the KubeadmControlPlane `kcp-cleanup`
  pre-terminate hook, which removes the etcd member and needs the now-dead control plane. We
  unblocked by annotating `machine.cluster.x-k8s.io/exclude-node-draining=true`, removing the
  `pre-terminate.delete.hook.machine.cluster.x-k8s.io/kcp-cleanup` annotation, and finally deleting
  the workload cluster's Azure resource group directly so CAPZ saw the resources gone and dropped
  its finalizers.
  - **Idea:** teardown should tolerate unreachable nodes by default. Set a short `nodeDrainTimeout`
    and `nodeDeletionTimeout` in the cluster templates, and have `hack/teardown-builder.sh` fall
    back to a direct `az group delete` of the workload RG when graceful deletion does not progress.
- **Forced teardown leaves CAPI objects behind, and a rebuild races with their deletion.** After
  force-clearing finalizers on the obvious objects, the `KubeadmControlPlane`, `AzureMachineTemplate`
  and `KubeadmConfig` still lingered. Re-running `setup-builder-cluster.sh` then applied a fresh
  `KubeadmControlPlane` over the still-deleting old one, whose deletion promptly removed the new one,
  so the control plane never initialized. We had to delete the half-built cluster, clear the orphaned
  template, and re-run.
  - **Idea:** a complete `teardown-builder.sh` should delete and verify every CAPI object kind for the
    cluster (control plane, templates, bootstrap configs) and confirm the namespace is empty before
    `setup-builder-cluster.sh` will proceed, or refuse to start when remnants exist.
- **`setup-builder-cluster.sh` reports success before the workers join.** `kubectl wait --for=
  condition=Ready nodes --all` returned as soon as the control-plane node registered, while the
  MachinePool worker was still provisioning. The script should wait for the expected worker count,
  not just `--all` against whatever has registered so far.
- **Takeaways for the setup scripts (to harden in the production phase):** make SKUs and regions
  configurable with available defaults and a fail-fast check; add drain/deletion timeouts to the
  builder cluster templates; and document a one-command recover-or-rebuild path so a reaped
  environment can be restored without ad hoc `kubectl annotate` and `az group delete` surgery.
