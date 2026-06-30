# AI and agentic technology stack

imogen is both a working image-curation system and a demonstration of running an
AI agent natively on Kubernetes. This page summarizes the AI and agentic
technologies it uses, for a quick management-level overview. See
[plan.md](plan.md) for the full design and [../AGENTS.md](../AGENTS.md) for the
implementation details.

## Core agent framework

- **kagent** — a Kubernetes-native agent framework. The orchestrator is a
  declarative kagent `Agent` running in our AKS management cluster, so the AI
  agent itself runs on Kubernetes. This is a deliberate strategic goal:
  dogfooding agentic AI on Kubernetes rather than as an external service.

## Language model

- **Azure OpenAI** (model **gpt-4.1-mini**), wired to the agent through a kagent
  `ModelConfig`. This is the reasoning engine that plans and drives the image
  pipeline.

## Tool and integration protocols

- **MCP (Model Context Protocol)** — our Go tool server exposes each pipeline
  action (list releases, build, validate, promote, retire, and so on) as an MCP
  tool the agent can call. It is built on the official MCP Go SDK.
- **A2A (Agent-to-Agent protocol)** — JSON-RPC streaming (`message/stream`,
  `tasks/resubscribe`) that the autonomous release-watcher uses to task the agent
  and follow long-running work durably, even when a single connection drops.

## Agentic patterns we demonstrate

- **Autonomous trigger loop** — a daily release-watcher detects new Kubernetes
  releases and has the agent reconcile them unattended, driving build, validate,
  and promote.
- **Human-approval gate** — destructive or publishing steps can pause for human
  confirmation. Promotion runs unattended in the watcher context while keeping
  the gate for interactive use, and image retirement always requires a human.
- **Self-managing infrastructure** — the agent provisions and scales its own
  build cluster (Cluster API for Azure plus cluster-autoscaler, scaling to zero
  when idle).

## Security model

- **Microsoft Entra Workload Identity** — fully secretless Azure authentication
  with no stored keys, aligning the AI agent with current Azure identity best
  practices.

## In one line

imogen runs an AI agent (kagent on AKS, powered by Azure OpenAI gpt-4.1-mini)
that drives a Kubernetes image pipeline through MCP tools and the A2A protocol,
authenticating to Azure with secretless Workload Identity.
