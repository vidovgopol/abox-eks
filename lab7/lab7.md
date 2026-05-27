# Vin's Questions — AI Infrastructure Self-Assessment

> Final assignment / interviewer questions. Answers are grounded in **this repo's actual stack** and verified against primary docs (kagent.dev, agentgateway.dev, kgateway.dev, gofastmcp.com, docs.vllm.ai, llm-d.ai). Where a capability exists in the tooling but is **not yet enabled in our cluster**, that is stated explicitly. Confidence notes are inline.

## Our stack, in one paragraph

EKS (`aire-eks`) running **kagent v0.9.2** as the agent framework. Agents are either `type: Declarative` (LLM + system prompt + MCP tools, ADK runtime) or `type: BYO` (a container, e.g. an ADK/A2A agent) — see [releases/agents/](releases/agents/). The default [`ModelConfig`](ai-infra/main.tf) `default-model-config` points at **Anthropic Claude `claude-sonnet-4-6`** via an API-key Secret — i.e. we currently use a **hosted model API**, not self-hosted inference. Ingress is **agentgateway v2.2.1** (`oci://ghcr.io/kgateway-dev/charts`, powered by kgateway), today doing only path routing (`/api`→`kagent-controller`, `/`→`kagent-ui`) — its LLM/AI-gateway features are not yet switched on. MCP tools run as kagent `MCPServer`/`RemoteMCPServer` CRs, some scaffolded with **kmcp + fastmcp-python** ([test-kmcp-server.yaml](releases/agents/test-kmcp-server.yaml)). Agents ship via **Flux GitOps** (`releases/` → OCI artifact on `git tag v*` → `prune=true`). We also run an **MCP Security Governance** controller and an **Agent Registry** in `ai-infra`.

The recurring theme below: **kagent is a thin agent runtime; resilience, routing, failover, and FinOps belong to the gateway layer (agentgateway/kgateway), and inference performance belongs to the serving layer (vLLM/llm-d).** Knowing which layer owns each concern is the whole answer to most of these questions.

---

## TL;DR matrix

| # | Question | Short answer |
|---|---|---|
| 1 | Handle "agent got stuck"? | No kagent-native step/timeout field. Bounded by ADK `max_llm_calls` (default 500) + **gateway request/backend timeouts** as the real backstop. |
| 2 | Auto timeout / circuit breaker from the framework? | **Not from kagent.** From **agentgateway**: request/backend timeouts, retries, and failover-eviction (outlier ejection). Classic circuit-breaker syntax unconfirmed for v2.2.1. |
| 3 | kgateway model failover? | **Yes** — `AgentgatewayBackend.spec.ai.groups` = ordered priority tiers; eviction on `429`/`5xx`/timeout via CEL `unhealthyCondition`. Not enabled in our cluster yet. |
| 4 | Auto-switch OpenAI → Claude → local? | **Yes**, same `groups` failover, mixing OpenAI + Anthropic + an OpenAI-compatible local (vLLM) backend. |
| 5 | Seamless response formats across providers? | **Yes** — gateway exposes one **OpenAI-compatible** schema and translates per provider. |
| 6 | Version kagent agents? | **No version field in the CR.** Versioning = container image tag (BYO) + **git tag / Flux OCI revision** (our effective version) + optional A2A AgentCard `version`. |
| 7 | Blue/green or canary for agents? | **Nothing kagent-native.** Use Gateway API weighted `backendRefs` + Argo Rollouts / Flagger. Watch session stickiness. |
| 8 | What is fastmcp-python? | A Pythonic MCP-server framework (decorator `@mcp.tool`); FastMCP 1.0 was merged into the official `mcp` SDK, FastMCP 2.x is the standalone project. |
| 9 | Easiest path to MCP? | **fastmcp = easiest authoring**, **kmcp = easiest k8s deploy** (handles image, CRD, stdio→HTTP bridge). Trade-offs below. |
| 10 | FinOps: how much control? | A lot — **at the gateway** (token rate limits, per-key budgets, usage metrics). Caveat: **token-based, not dollar-based**; $ is a manual conversion. |
| 11 | Token-level / per-agent level? | Token-level: yes (`rateLimit` `tokens`, `ModelConfig.maxTokens`). Per-agent: requires routing per agent (separate route/backend/virtual-key), since today agents share one key. |
| 12 | Custom cost controls? | Yes — gateway token limits + global rate-limit descriptors + guardrails, plus app-level `max_llm_calls`, plus our MCP Governance policy scoring. |
| 13 | Per-agent budgets / token-depth limits? | Via per-agent virtual keys + token rate limits at the gateway; `ModelConfig.maxTokens` caps per-response depth. Not on by default. |
| 14 | vLLM for many tool-call round-trips, or single-shot? | **Both.** Automatic Prefix Caching makes the growing-prefix agentic loop efficient; tool-calling is served natively. |
| 15 | Does llm-d's scheduler help with ~15 calls? | **Yes** — prefix-cache-aware (KV-cache-aware) routing pins the 15 calls to the replica that already holds the prefix. It routes; it does **not** reduce call count. |

---

# A. Agent reliability

## 1. How could we handle "agent got stuck" scenarios?

**There is no kagent-native knob** — no `maxIterations`, `maxSteps`, `timeout`, or termination-condition field on the `Agent` CRD (`AgentSpec`/`DeclarativeAgentSpec` only expose `runtime`, `systemMessage`, `modelConfig`, `tools` (max 20), `stream`, `a2aConfig`, deployment fields). There are also no liveness/readiness probe fields in the CRD. *(Confidence: high — read from the kagent Go CRD source.)*

What actually bounds a run, layer by layer — and how we'd use each:

1. **Runtime bound (ADK):** kagent's Declarative runtime wraps **Google ADK**. ADK's `RunConfig.max_llm_calls` caps total LLM calls per run (**default 500**); exceeding it raises `LlmCallsLimitExceededError`. Caveat: this guard does **not** apply to bidirectional live streaming. There is **no per-tool or per-run wall-clock timeout in ADK RunConfig** — so a tool that hangs is *not* stopped by ADK.
2. **Gateway timeout (the real backstop for a hung tool/model):** because the framework won't kill a hung call, the dependable stop is an **agentgateway request/backend-request timeout** in front of the model and MCP backends. This is what turns "stuck forever" into "fails fast and retries/fails over."
3. **Kubernetes bound:** since kagent renders a normal Deployment, we can patch a **liveness probe** / set `activeDeadlineSeconds` on long jobs out-of-band, and rely on resource limits so a runaway agent can't starve the node.
4. **Tool design:** keep MCP tools idempotent and read-first (our `kubagent` system prompt already enforces "read-only before changes; never delete without confirmation") so a stuck loop is safe to kill and retry.

**Recommendation for our cluster:** add a gateway timeout + retry policy on the model/MCP routes (see Q2), and consider surfacing ADK `max_llm_calls` on BYO agents. Treat a stuck agent as a *transport* problem solved at the gateway, not in kagent.

## 2. Any automatic timeout / circuit-breaker patterns coming out of this framework?

**Not from kagent.** kagent CRDs expose no retry, timeout, or circuit-breaker logic. The only model-side timeout is `ModelConfig.openAI.timeout` (**OpenAI only**) — our Anthropic `ModelConfig` has no timeout/retry field. *(Confidence: high — CRD source.)*

**From agentgateway (the resilience layer), yes:**
- **Timeouts** — two kinds: request timeout (whole client↔backend lifecycle) and backend-request timeout (per upstream call). Configurable via Gateway API `HTTPRoute.spec.rules[].timeouts.request` or an `AgentgatewayPolicy.spec.traffic.timeouts.request`.
- **Retries** — `attempts`, `backoff`, retry-on `codes` (e.g. `[500, 503]`), via `HTTPRoute.spec.rules[].retry` or `AgentgatewayPolicy.spec.traffic.retry`.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
spec:
  traffic:
    timeouts: { request: 30s }
    retry: { attempts: 3, backoff: 1s, codes: [500, 503] }
```

- **"Circuit breaker" equivalent** — the documented primitive is **failover health/eviction** (per-backend outlier ejection): `AgentgatewayPolicy.spec.backend.health` with a CEL `unhealthyCondition` (e.g. `response.code == 429 || response.code >= 500`) and an `eviction` block (`duration`, `consecutiveFailures`). A `429` with `Retry-After` is honored; repeated evictions back off multiplicatively. A classic Envoy-style circuit-breaker / connection-pool-limit CRD was **not confirmed** for agentgateway v2.2.1 — the eviction mechanism is what we'd use. *(Confidence: high on timeouts/retries/eviction; explicitly unconfirmed on a dedicated circuit-breaker block.)*

> **State of our cluster:** none of these policies are applied today — agentgateway is only doing path routing. This is the highest-value hardening to add.

---

# B. Model routing & failover

## 3. How does kgateway handle model failover?

agentgateway/kgateway (v2.2.x) is an **LLM gateway**: it routes to OpenAI, Azure OpenAI, **Anthropic**, Gemini, Vertex, Bedrock, and any OpenAI-compatible/self-hosted backend (vLLM, Ollama, …). Failover is configured on an **`AgentgatewayBackend`** via **`spec.ai.groups`** — an ordered list of priority tiers. Group order = failover order; multiple providers within one group are load-balanced (Power-of-Two-Choices). Eviction (what triggers failover) comes from the health/`unhealthyCondition` policy in Q2.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: { name: llm, namespace: agentgateway-system }
spec:
  ai:
    groups:
      - providers:                       # tier 1 — primary
          - name: anthropic-sonnet
            anthropic: { model: claude-sonnet-4-6 }
            policies: { auth: { secretRef: { name: anthropic-api-key } } }
      - providers:                       # tier 2 — fallback
          - name: openai-gpt
            openai: { model: gpt-4.1 }
            policies: { auth: { secretRef: { name: openai-secret } } }
```

*(Confidence: high on the `groups`/priority/P2C/eviction model; verify exact field nesting against the installed CRD — see the CRD-generation note at the end.)*

> **Note:** the **exact CRD names depend on the installed chart generation.** v2.2.x uses agentgateway-native `AgentgatewayBackend` / `AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`); the older Envoy-based kgateway used `Backend` (`spec.type: AI`) + `TrafficPolicy` (`gateway.kgateway.dev/v1alpha1`). Confirm with `kubectl get crd | grep -E 'agentgateway|kgateway'`.

## 4. Can we automatically switch from OpenAI to Claude to local model?

**Yes** — that's exactly the `groups` mechanism above, just with three tiers mixing providers. A self-hosted **local** model (vLLM) is declared as an **OpenAI-compatible** provider (`openai` block with `host`/`port`), so a single backend can fail over **OpenAI → Claude → local vLLM** (or any order) on error/timeout/`429`:

```yaml
spec:
  ai:
    groups:
      - providers: [ { name: oai, openai:    { model: gpt-4.1 } } ]
      - providers: [ { name: cla, anthropic: { model: claude-sonnet-4-6 } } ]
      - providers: [ { name: loc, openai: { model: llama-3.1-8b, host: vllm.inference.svc, port: 8000 } } ]
```

For our setup the cleanest design is to point kagent's `ModelConfig` at the **gateway** (one OpenAI-compatible endpoint) and let the gateway own provider selection/failover — rather than hard-coding Anthropic in the ModelConfig as we do today. *(Confidence: high on the gateway capability; the kagent-ModelConfig-points-at-gateway wiring is a recommended design we have not yet implemented.)*

## 5. Could we seamlessly handle the response formats from these providers?

**Yes.** The AI gateway's core value is a **unified, OpenAI-compatible API**: the client always sends `POST /v1/chat/completions` (one schema), and the gateway translates request/response to each provider's native API (Anthropic Messages, Gemini, Bedrock, …). Switching or failing over between providers needs **no client/agent code change**. v2.2.x also adds model aliases and path-based routing for `completions`/`messages`/`models`/`passthrough`. Caveat: "passthrough" mode and some non-chat shapes (embeddings, native Messages) are not all normalized — verify per endpoint. *(Confidence: high on the unified OpenAI schema; medium on full normalization of every non-chat format.)*

---

# C. Agent lifecycle

## 6. Can we version the agents built from kagent?

**There is no `version` field in the kagent `Agent` CR** (`AgentStatus` is only `observedGeneration` + `conditions`). *(Confidence: high — CRD source.)* In practice, versioning comes from layers we already have:

- **BYO agents → container image tag.** Our `support-agent` already does this: `image: docker.io/vidovgopol/support_agent:test-v6` — the tag *is* the version of record.
- **GitOps revision (our effective version).** Flux packages [releases/agents/](releases/agents/) into an OCI artifact on `git tag v*` and applies with `prune=true`. The **git tag / OCI digest is the agent version**, and Flux's `OCIRepository`/`Kustomization` status records the applied revision. This is the concrete "where a version lives" in our architecture.
- **ModelConfig pinning.** Pin `ModelConfig.spec.model` (e.g. `claude-sonnet-4-6`) and treat model changes as a versioned behavior change.
- **A2A AgentCard `version`.** The A2A protocol AgentCard kagent exposes includes a `version` field — available by protocol, but kagent leaves it empty by default; for BYO ADK agents we can populate it ourselves.

**Recommendation:** standardize on `git tag` = release version, and stamp the same value into BYO image tags + the A2A AgentCard so the version is consistent across all three views.

## 7. Any blue/green or canary deployment patterns for agents?

**Nothing kagent-native** (no rollout/traffic-split fields; kagent just renders a `Deployment` + `Service`). But because that's all it produces, standard progressive-delivery tooling applies:

- **BYO agents** = Deployment behind a Service → use **Gateway API weighted `backendRefs`** (we already run Gateway API + agentgateway) for canary, optionally driven by **Argo Rollouts** or **Flagger**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  rules:
    - backendRefs:
        - { name: support-agent-v1, port: 8080, weight: 90 }
        - { name: support-agent-v2, port: 8080, weight: 10 }
```

- **Declarative agents** are harder to traffic-split (the controller owns one Deployment/Service per `Agent` CR). De-facto pattern: create a **second `Agent` CR** (`kubagent-v2`) and weight-split between the two Services; or do a straight GitOps replace via a new `git tag`.
- **Caveat (important for agents):** agent sessions are **stateful** (A2A sessions, memory). Naive request-weighted splitting can split one conversation across versions — prefer **session affinity** or canary **by new sessions only**. kagent gives no built-in stickiness for this.

*(Confidence: high that kagent has nothing native and that BYO works with Argo Rollouts/Flagger/Gateway API; the Declarative two-CR pattern is a reasoned recommendation.)*

---

# D. MCP tooling

## 8. What's the fastmcp-python framework mentioned?

**FastMCP** (gofastmcp.com, maintained by Jeremiah Lowin under Prefect) is "the fast, Pythonic way to build MCP servers." You define tools with decorators and Python type hints; it auto-generates the JSON-Schema, validation, and wire protocol.

```python
from fastmcp import FastMCP
mcp = FastMCP("Demo 🚀")

@mcp.tool
def add(a: int, b: int) -> int:
    """Add two numbers"""
    return a + b

if __name__ == "__main__":
    mcp.run()          # stdio by default; or transport="http"
```

Key facts:
- **FastMCP 1.0** was successful enough that its core was **merged into the official MCP Python SDK** (`from mcp.server.fastmcp import FastMCP`). **FastMCP 2.x** is the standalone, actively maintained package (`pip install fastmcp`) with clients, server proxying/composition, OpenAPI generation, and auth. **3.0** is in beta (announced 2026-01-20).
- **Transports:** `stdio` (default), `http` (Streamable HTTP), `sse` (legacy/deprecated).
- This is the framework behind our [test-kmcp-server.yaml](releases/agents/test-kmcp-server.yaml) (`kmcp.dev/framework: fastmcp-python`). *(Confidence: high.)*

## 9. Is it the easiest path to MCP?

Split into authoring vs deploying:

- **Authoring — fastmcp is the easiest in Python.** Decorator + type-hint model removes JSON-RPC boilerplate; it's effectively the de-facto idiom (its 1.0 core lives inside the official SDK). Alternatives: raw low-level `mcp` SDK (more control, more boilerplate), **mcp-go** (best when you want one tiny static binary), TypeScript SDK (common for `npx`-distributed servers).
- **Deploying to k8s — kmcp is plausibly the easiest.** [kmcp](https://github.com/kagent-dev/kmcp) (the kagent project's CLI + controller) removes the three painful steps: writing a Dockerfile, hand-writing Deployment/Service, and bridging **stdio→network**. Workflow: `kmcp init python …` → `kmcp run` (local + MCP Inspector) → `kmcp build` → `kmcp install` (controller) → `kmcp deploy` (creates the `MCPServer` CR, reachable over Streamable HTTP at `…:3000/mcp`). It scaffolds either fastmcp-python or mcp-go.
- **Alternatives / trade-offs:**
  - `uvx`/`npx` stdio servers (our [mcp-website-fetcher.yaml](releases/agents/mcp-website-fetcher.yaml) runs `uvx mcp-server-fetch`) — trivial, but a bare stdio process **has no network listener**, so in-cluster it needs a wrapper to be reachable. kmcp's "Transport Adapter" provides exactly that stdio→HTTP bridge.
  - **Remote/hosted MCP** via kagent `RemoteMCPServer` (our `kagent-tool-server`) — *easiest of all when a suitable endpoint already exists*; zero packaging, just point at a URL.
- **Honest verdict:** for **Python authoring**, yes — fastmcp is the easiest path. For **deployment**, kmcp is the easiest *if you're staying in the kagent ecosystem*; otherwise raw SDK + handwritten manifests (max control, max toil) or ToolHive-style operators are alternatives. Note the transport reality: in-cluster you want **Streamable HTTP**, and kmcp/agentgateway add federation (multiple MCP servers behind one endpoint with name-prefixed tools). *(Confidence: high on trade-offs; "easiest" is a judgment, framed as a recommendation.)*

---

# E. FinOps

## 10. How much control can I have?

A lot — but the control lives **at the gateway**, and it is **token-based, not dollar-based**. agentgateway emits a Prometheus metric **`agentgateway_gen_ai_client_token_usage`** (labels: `gen_ai_token_type` input/output, `gen_ai_system` provider, `gen_ai_request_model`, `gen_ai_response_model`) plus OTel `gen_ai.usage.*` span attributes. So we get fine-grained **visibility** per provider/model/route, and **enforcement** by token budget. There is **no built-in dollar-cost calculation or $-budget enforcement** — converting tokens→$ is a manual PromQL/pricing step and per-model spend dashboards are operator-built. *(Confidence: high, incl. the explicit "no native $ enforcement.")*

Three layers of control available to us:
1. **Gateway** — token rate limits, per-key budgets, usage metrics (below).
2. **Model config** — `ModelConfig.maxTokens` caps output tokens per response (a crude per-call cost ceiling).
3. **Application/runtime** — ADK `max_llm_calls` caps calls per agent run; our **MCP Governance** policy ([mcp-governance-policy.yaml](ai-infra/mcp-governance-policy.yaml)) scores `requireRateLimit`, `maxToolsWarning/Critical`, etc. — a governance/visibility layer.

## 11. Token level / per-agent level

- **Token level — yes.** `AgentgatewayPolicy.spec.traffic.rateLimit.local[].tokens` (with `unit: Seconds|Minutes|Hours`) enforces an actual token budget; the gateway reads the LLM response `usage` field. Token limits are enforced **post-stream** (a streaming response can't be cut mid-flight, so the budget applies to the *next* request). Plus `ModelConfig.maxTokens` per response.

```yaml
spec:
  targetRefs: [ { group: gateway.networking.k8s.io, kind: HTTPRoute, name: claude } ]
  traffic:
    rateLimit:
      local: [ { tokens: 100000, unit: Hours } ]
```

- **Per-agent level — possible but requires routing per agent.** Today all our agents share one `ModelConfig` → one Claude key, so the gateway sees *aggregate* traffic. To budget *per agent* we'd either give each agent its own route/backend, or inject an agent identifier and key a **global** rate-limit on it (see Q13). *(Confidence: high on token-level; per-agent is a design we'd add.)*

## 12. Can I implement custom cost controls?

Yes, composing the layers:
- **Token rate limits** (local) per route/model — hard caps.
- **Global rate limiting** with `descriptors` keyed on a consumer/agent identity (`unit: Tokens`) via an external rate-limit service — per-tenant/per-agent budgets.
- **Guardrails** (`promptGuard`) to *reject* expensive or disallowed request patterns before they hit the model.
- **App-level** ADK `max_llm_calls` to cap the tool-loop depth (directly limits calls-per-task, the main agentic cost driver).
- **Governance** — our MCP Governance controller scores/flags policy violations (`requireRateLimit`, tool-count thresholds) for continuous FinOps/security posture.

*(Confidence: high that these primitives exist; they are not yet wired in our cluster.)*

## 13. Per-agent budgets or depth of token limits

- **Per-agent budgets** — implement via **"virtual keys"**: inbound `apiKeyAuthentication` (a Secret mapping each key to per-agent metadata) + a **global** token rate-limit whose descriptor is keyed on that metadata. Each agent gets its own key → its own token budget:

```yaml
spec:
  traffic:
    apiKeyAuthentication: { mode: Strict, secretRef: { name: agent-api-keys } }
    rateLimit:
      global:
        backendRef: { kind: Service, name: rate-limit-server, port: 8081, namespace: agentgateway-system }
        descriptors:
          - entries: [ { name: agent_id, expression: 'apiKey.metadata.agent_id' } ]
            unit: Tokens
```

- **Depth of token limits** — two senses: (a) **output depth per call** = `ModelConfig.maxTokens`; (b) **conversation/loop depth** = ADK `max_llm_calls` (caps how many model round-trips one agent task can make — directly caps the cumulative token spend of a runaway tool loop). Combine both for a per-agent ceiling. *(Confidence: high on the mechanisms; medium on exact `descriptors`/`expression` schema — verify against the installed CRD.)*

---

# F. Inference serving (forward-looking — we use the Claude API today)

## 14. Is vLLM suitable for agents with many back-and-forth tool calls, or better for single-shot?

**Both — it is not an either/or, and the multi-turn agentic case is specifically what vLLM optimizes.**

- **Automatic Prefix Caching (APC)** is the agentic feature. It "caches the KV cache of existing queries, so a new query can directly reuse the KV cache if it shares the same prefix." In a tool loop, each follow-up call is `[system + tool defs + prior turns + new tool result]` — the first N-1 turns are a stable prefix served from cache instead of re-prefilled. With 15+ calls sharing a growing prefix, the savings compound. Flag: `--enable-prefix-caching` (**on by default in vLLM V1**). Honest limit: APC accelerates *prefill*, not *decode*.
- **PagedAttention + continuous batching** keep the GPU saturated under many concurrent agent calls (paper claims 2–4× throughput vs prior serving at similar latency — their benchmark, not a prediction for our hardware).
- **Native tool calling** in vLLM's OpenAI-compatible server: `--enable-auto-tool-choice`, `--tool-call-parser <model>`, plus guided/structured decoding for `tool_choice: required`. So vLLM can serve the tool-calling loop directly.

**Verdict:** vLLM is fine for single-shot *and* well-suited to many-round-trip agents; APC makes the repeated-prefix pattern efficient. *(Confidence: high.)*

## 15. Does llm-d's scheduler help when an agent makes ~15 LLM calls?

**Yes — agentic flows are a headline use case — but be precise: the scheduler routes/places calls; it does not reduce how many calls the agent makes.**

- **llm-d** = Kubernetes-native distributed inference (vLLM-based; IBM/Red Hat/Google), built on the **Gateway API Inference Extension** (Inference Gateway + **InferencePool** + **EPP / Endpoint Picker**).
- The EPP scheduler scores endpoints with **prefix-cache-aware** + **load-aware** scorers and maintains a real-time view of distributed KV-cache state (**KVEvents** from the vLLM pods). It then "routes subsequent requests from the same conversation or **agent loop** back to whichever pod already holds their prefix." It also supports **prefill/decode disaggregation** and session/prefix affinity.
- **Why this matters for 15 sequential calls with a growing shared prefix:** a naive round-robin LB "scatters related requests across different pods and destroys cache locality" — each new pod is cache-blind and re-prefills the whole history (high TTFT + wasted compute). llm-d pins the 15 calls to the cache-affine replica → repeated APC hits → lower TTFT and cost. (llm-d's published figures: a single-pod APC example 4.3s→0.6s TTFT; "precise vs approximate" scheduling 57× faster P90 TTFT — their benchmarks, with their hardware/workload.)
- **What it does NOT do:** it won't merge or cut the agent's calls — that's an agent-design concern (`max_llm_calls`, better prompting/tool use). *(Confidence: high on mechanism; figures are cited from llm-d primary sources, not predictions for our cluster.)*

### How this would connect to our stack
agentgateway/kgateway can route to an **OpenAI-compatible** backend and **implement the Inference Gateway extension** (InferencePool/EPP) for local LLMs. So a vLLM (or llm-d) endpoint slots in as a provider behind our existing gateway, and kagent's `ModelConfig` points at it. **Confirmed:** gateway supports OpenAI-compatible + inference-extension routing; vLLM is OpenAI-compatible. **Plausible / to-verify:** exact kagent ModelConfig wiring to a self-hosted OpenAI endpoint, and whether our installed agentgateway chart already enables the InferencePool/EPP path. *(Honest: this is an architecture we'd build and test, not something running today.)*

---

# What we'd add to productionize (gap summary)

| Concern | Today | To add |
|---|---|---|
| Stuck/hung agents (Q1–2) | nothing enforced | gateway request/backend **timeouts + retries + eviction**; ADK `max_llm_calls`; liveness probe on Deployment |
| Model failover (Q3–5) | single hard-coded Claude ModelConfig | gateway `AgentgatewayBackend.groups` multi-provider failover; point ModelConfig at the gateway |
| Versioning (Q6) | image tags + git tags | standardize git tag = release version, stamp into image tag + A2A AgentCard |
| Canary/blue-green (Q7) | straight GitOps replace | Gateway API weighted `backendRefs` + Argo Rollouts/Flagger, with session affinity |
| FinOps (Q10–13) | governance scoring only | gateway token rate limits, virtual keys per agent, token-usage dashboards (+ manual $ conversion) |
| Inference cost/perf (Q14–15) | hosted Claude API | optional self-hosted vLLM/llm-d behind the gateway for prefix-cache-aware agentic serving |

---

## Caveats / things to verify on the live cluster

1. **agentgateway CRD generation.** Run `kubectl get crd | grep -E 'agentgateway|kgateway'`. v2.2.x exposes `AgentgatewayBackend` / `AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`); the older model used `Backend` (type AI) + `TrafficPolicy`. Field paths in the snippets above assume the v2.2.x native CRDs — confirm with `kubectl explain`.
2. **kagent `max_llm_calls`** — ADK's default is 500, but whether kagent overrides it is unconfirmed (the Python engine ships as the separate `kagent-adk` package).
3. **Circuit breaker** — only timeouts/retries/eviction are confirmed for agentgateway v2.2.1; a classic circuit-breaker block was not.
4. **Self-hosted inference** — none deployed; Q14–15 are forward-looking design, grounded in vLLM/llm-d docs.

## Primary sources

- kagent: <https://kagent.dev/docs> · CRD source `github.com/kagent-dev/kagent/blob/main/go/api/v1alpha2/agent_types.go`
- agentgateway: failover <https://agentgateway.dev/docs/kubernetes/latest/llm/failover/> · rate-limit <https://agentgateway.dev/docs/kubernetes/latest/llm/rate-limit/> · virtual keys <https://agentgateway.dev/docs/kubernetes/latest/llm/virtual-keys/> · cost tracking <https://agentgateway.dev/docs/kubernetes/latest/llm/cost-tracking/> · guardrails <https://agentgateway.dev/docs/kubernetes/latest/llm/guardrails/overview/> · timeouts <https://agentgateway.dev/docs/kubernetes/latest/resiliency/timeouts/request/>
- Google ADK RunConfig: <https://google.github.io/adk-docs/runtime/runconfig/>
- FastMCP: <https://gofastmcp.com> · kmcp: <https://github.com/kagent-dev/kmcp> · <https://kagent.dev/docs/kmcp/quickstart>
- vLLM APC: <https://docs.vllm.ai/en/latest/features/automatic_prefix_caching.html> · tool calling: <https://docs.vllm.ai/en/latest/features/tool_calling.html>
- llm-d: <https://llm-d.ai/> · intelligent scheduling <https://llm-d.ai/blog/intelligent-inference-scheduling-with-llm-d> · Gateway API Inference Extension <https://gateway-api-inference-extension.sigs.k8s.io/>
