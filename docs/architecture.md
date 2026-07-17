# Architecture

Diagrams of the imogen stack and its moving pieces. These use
[Mermaid](https://mermaid.js.org/), which GitHub renders inline. For the narrative design see
[plan.md](plan.md); for the AI/agentic technologies see [ai-stack.md](ai-stack.md).

## High-level stack

imogen keeps Kubernetes node reference images in an Azure Community Gallery current. A daily trigger
asks a kagent agent to reconcile upstream Kubernetes releases against the published gallery, and the
agent drives a build → validate → promote → retire pipeline exposed as MCP tools. Everything
authenticates to Azure with Workload Identity, so no secrets are stored.

```mermaid
flowchart TB
  subgraph upstream["Upstream"]
    k8s["Kubernetes releases<br/>(release feed)"]
    ib["image-builder container<br/>registry.k8s.io"]
  end

  subgraph aks["AKS management cluster (always on)"]
    direction TB
    watcher["release-watcher CronJob<br/>(daily, hack/reconcile.sh)"]
    agent["kagent Agent<br/>(orchestrator)"]
    proxy["imogen-aoai-proxy<br/>(token-injecting reverse proxy)"]
    ts["imogen-toolserver<br/>(MCP tools)"]
    capz["CAPZ + cluster-autoscaler"]
    watcher -->|A2A message/stream| agent
    agent -->|MCP| ts
    agent -->|model calls| proxy
  end

  subgraph builder["CAPZ builder workload cluster (scales 0..N)"]
    direction TB
    buildjob["image-builder Job"]
    valnode["validation node<br/>(booted from staging image)"]
  end

  subgraph azure["Azure"]
    aoai["Azure OpenAI"]
    staging["Staging gallery<br/>imogen_staging"]
    community["Community gallery<br/>imogen_community (published)"]
  end

  human["Human (Slack/Teams via notify,<br/>approval gate on promote)"]

  k8s -.->|list-k8s-releases| ts
  ib -.->|pulled by| buildjob
  ts -->|submit-build-job / scale| capz
  capz -->|manages| builder
  ts -->|validate-image| valnode
  buildjob -->|publishes| staging
  valnode -.->|boots from| staging
  ts -->|promote-image| community
  staging -->|promote copy| community
  proxy --> aoai
  ts -->|notify| human
  agent -.->|approval request| human

  classDef gallery fill:#e8f0fe,stroke:#4285f4;
  class staging,community gallery;
```

## Deployment and identity

Where each component runs and how it authenticates. The management cluster is always on; the builder
cluster's worker pool scales to zero between runs. Auth is Workload Identity throughout, except the
local kind path which uses the developer's `az` login.

```mermaid
flowchart LR
  subgraph mgmt["AKS management cluster"]
    direction TB
    agentD["Deployment: imogen (agent)"]
    tsD["Deployment: imogen-toolserver"]
    proxyD["Deployment: imogen-aoai-proxy"]
    cron["CronJob: imogen-release-watcher"]
    ca["cluster-autoscaler"]
    capi["CAPZ controllers"]
  end

  subgraph ids["Managed identities (federated)"]
    idTs["imogen-toolserver<br/>Contributor on RG,<br/>OpenAI User, MI Operator"]
    idCapz["imogen-capz<br/>Contributor on sub"]
    idBuild["build identity<br/>Contributor on sub"]
  end

  subgraph builderC["CAPZ builder cluster"]
    vmss["worker VMSS<br/>(build + validation)"]
  end

  subgraph azureR["Azure resources"]
    galleries["staging + community galleries"]
    openai["Azure OpenAI account"]
  end

  tsD -->|azure.workload.identity/use| idTs
  proxyD -->|federated cred| idTs
  cron -->|same image as toolserver| tsD
  capi -->|AzureClusterIdentity WorkloadIdentity| idCapz
  vmss -->|IMDS| idBuild

  idTs --> galleries
  idTs --> openai
  idCapz -->|creates/scales| builderC
  idBuild -->|Packer build VM| galleries
  ca -->|scale 0..N| vmss
```

## Reconcile sequence

The unattended daily reconcile. The shell loop (`reconcile.sh`) provides persistence: it re-invokes
the agent each pass until `list-reconcile-plan` reports `upToDate` or `stuck`, because the model
reliably ends a turn while work is still in flight. Builds (Kubernetes Jobs) and validations
(goroutines in the tool server, serialized per OS type) keep running server-side between passes, and
`submit-build-job` / `validate-image` are idempotent, so each pass just promotes whatever finished and
advances the rest. The unattended watcher auto-promotes validated images and auto-retires minors more
than a year past EOL; interactive runs require human approval for both.

```mermaid
sequenceDiagram
  autonumber
  participant Cron as release-watcher CronJob
  participant Sh as reconcile.sh (loop)
  participant Agent as kagent Agent
  participant Tools as toolserver (MCP)
  participant Builder as CAPZ builder cluster
  participant Gallery as Azure galleries

  Cron->>Sh: run hack/reconcile.sh
  loop until upToDate or stuck or deadline
    Sh->>Agent: A2A message/stream (reconcile prompt)
    Agent->>Tools: list-reconcile-plan
    Tools-->>Agent: work list (build / validate-promote), blocked flags
    alt version needs building
      Agent->>Tools: submit-build-job(flavor, version)
      Tools->>Builder: apply build Job (autoscaler scales 0->N)
      Builder->>Gallery: publish to staging gallery
      Agent->>Tools: get-build-status (polls, throttled)
    end
    alt staging image needs validating
      Agent->>Tools: validate-image(flavor, version)
      Tools->>Builder: boot node from staging image, assert Ready+version+smoke
      Agent->>Tools: get-validation-status (polls, throttled)
    end
    alt validated, ready to promote
      Agent->>Tools: promote-image (gate: validation must have Succeeded)
      Tools->>Gallery: copy staging -> community (--no-wait)
      Agent->>Tools: get-promote-status (polls, throttled)
    end
    Agent->>Tools: gc-eol-images apply=true, retire minors past EOL grace
    Agent->>Tools: notify summary, level=approval if a human is needed
    Sh->>Agent: next pass if not upToDate
  end
  Sh-->>Cron: exit 0 (upToDate) or non-zero (stuck)
```
