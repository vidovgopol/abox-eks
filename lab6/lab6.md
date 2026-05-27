# Lab 6 — Integrate our own agent with RAG (Qdrant)

> **Goal:** give a kagent agent Retrieval-Augmented Generation over our own knowledge corpus, using the **Qdrant we already run** in the cluster.
> Reference example: <https://qdrant.tech/documentation/embeddings/gemini> (we use the same store→embed→search pattern, with our chosen building blocks below).

## Decisions for this lab

| Decision | Choice | Why |
|---|---|---|
| RAG component | **Official `qdrant/mcp-server-qdrant`** exposed as a kagent `MCPServer` | Fastest path, least code; slots into our existing MCP + GitOps pattern (same shape as [mcp-website-fetcher.yaml](../releases/agents/mcp-website-fetcher.yaml)). |
| Embeddings | **Local `fastembed`** (`sentence-transformers/all-MiniLM-L6-v2`, 384-dim, COSINE) | The official server supports **only** fastembed. Fully self-hosted, **no external API/key, zero token cost**. |
| Agent | A new **Declarative** kagent agent that calls the `qdrant-find` tool | Uses our default Claude `ModelConfig`; "our own agent" doing RAG via a tool. |
| Delivery | **Flux GitOps** (`releases/agents/`) for the MCP server + agent; **Terraform** (`ai-infra`) for the Qdrant key secret | Keeps the secret out of git; everything else is a tagged GitOps release. |

> **Note on the OpenAI-embeddings idea:** the *official* server is fastembed-only. OpenAI embeddings would require a community fork (`andrewlwn77/qdrant-mcp`, `mhalder/qdrant-mcp-server`) + an `openai-api-key` Secret + recreating the collection at 1536-dim. That's documented as an optional swap in [§8](#8-optional-enhancements), not the baseline.

---

## ✅ Deployed & verified (as-built, 2026-05-27)

This is **running in the `aire-eks` cluster now** (deployed via `kubectl`, not yet GitOps). Manifests: [deploy/qdrant-mcp.yaml](deploy/qdrant-mcp.yaml), [deploy/rag-agent.yaml](deploy/rag-agent.yaml), [deploy/ingest-job.yaml](deploy/ingest-job.yaml).

**One design change vs the plan below** (found by checking the live CRD): the kmcp `MCPServer` CRD injects `secretRefs` as **mounted volumes**, not env vars, and `env` is plaintext-only — so it can't deliver `QDRANT_API_KEY` (which `mcp-server-qdrant` reads from the environment) without committing the key. So instead of an `MCPServer` CR, the official server runs as a plain **Deployment + Service** (`QDRANT_API_KEY` via `secretKeyRef`) and is registered with kagent as a **`RemoteMCPServer`**. Everything else (fastembed, collection, agent, ingestion-via-`qdrant-store`) is as planned.

**What got deployed**
- `Secret qdrant-api-key` in ns `kagent` (value copied from the `qdrant` ns — never in git).
- `Deployment/Service qdrant-rag` (ns `kagent`): official `mcp-server-qdrant` (v0.8.1) on `--transport streamable-http` at `:8000/mcp`, fastembed `all-MiniLM-L6-v2`, pointed at `qdrant.qdrant.svc:6333`, collection `knowledge-base`.
- `RemoteMCPServer qdrant-rag` → `http://qdrant-rag.kagent.svc.cluster.local:8000/mcp` (ACCEPTED; kagent discovered `qdrant-find` + `qdrant-store`).
- `Agent rag-agent` (Declarative, on `default-model-config` / Claude) — READY.
- `Job rag-ingest` seeded **6 cluster-specific facts** through `qdrant-store`.

**Verification evidence**
- Qdrant collection `knowledge-base`: **6 points**, named vector `fast-all-minilm-l6-v2`, **size 384, COSINE** (matches fastembed model — confirms ingest/query schema agree).
- `kagent invoke --agent rag-agent` trace shows: agent → `qdrant-find(query)` → vector hits → grounded answer **with `source` citation**.
  - *In-corpus* "K8s version / node type?" → "1.34 / t3.medium … eu-central-1", cited `infra/eks`. ✓
  - *Negative control* "Postgres admin password?" → "I don't have that in the knowledge base." ✓ (grounded, no hallucination)
  - *In-corpus* "embedding model?" → "all-MiniLM-L6-v2, 384-dim, cosine", cited `infra/rag`. ✓

**Re-run / inspect**
```bash
# pods + registration
kubectl get deploy,svc,remotemcpserver,agent -n kagent -l app=qdrant-rag
kubectl get remotemcpserver qdrant-rag -n kagent -o jsonpath='{.status.discoveredTools[*].name}'
# collection
kubectl exec -n kagent deploy/qdrant-rag -- python -c "from qdrant_client import QdrantClient;import os;c=QdrantClient(url=os.environ['QDRANT_URL'],api_key=os.environ['QDRANT_API_KEY']);print(c.get_collection('knowledge-base'))"
# ask the agent
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &
kagent invoke --agent rag-agent --task "Which embedding model does our RAG knowledge base use?"
```

> **GitOps follow-up (not yet done):** to make this survive/declarative, move the `qdrant-mcp.yaml` Deployment+Service and the `RemoteMCPServer`+`Agent` into `releases/agents/` (add to its `kustomization.yaml`), keep the `qdrant-api-key` Secret in Terraform (`ai-infra`), then `git tag v*` so Flux applies it.

---

## 1. What we already have (reuse)

- **Qdrant** running in ns `qdrant` (Helm release `qdrant`, gp3 PVC, auth on). Service: `qdrant.qdrant.svc.cluster.local`, REST `:6333`, gRPC `:6334`. API key in Secret `qdrant-api-key` (key `api-key`) — see [ai-infra/main.tf](../ai-infra/main.tf).
- **kagent** (ns `kagent`) with `default-model-config` → Claude `claude-sonnet-4-6`.
- **MCP pattern**: `uvx`-based stdio MCP servers as `MCPServer` CRs (kagent bridges stdio→HTTP at the pod port).
- **GitOps**: edit `releases/`, `git tag v*`, Flux applies with `prune=true`.
- **agentgateway** MCP federation + **MCP Governance** controller (the new server is governed automatically).

## 2. Architecture / data flow

```
                INGESTION (one-off / on corpus change)
  docs ─► chunk ─► [ingest Job] ──MCP qdrant-store──► mcp-server-qdrant
                                                          │ fastembed (all-MiniLM, 384d)
                                                          ▼
                                                  Qdrant collection "knowledge-base"
                                                  (named vector, COSINE, payload.document)

                QUERY (per user question)
  user ─► RAG Agent (Claude) ──tool: qdrant-find(query)──► mcp-server-qdrant
                                                          │ embed query → vector search top-k
                                                          ▼
                              top-k {document, metadata} ─► back to agent ─► grounded answer + citations
```

Same embedding model is used for **ingest and query** (the server guarantees this — both go through fastembed). Collection is **auto-created** on first store with the model's dimensions.

## 3. Components to create

```
ai-infra/                 (Terraform — secret only, stays out of git)
  + kubectl_manifest "qdrant_key_kagent"   → Secret qdrant-api-key in ns kagent (key QDRANT_API_KEY)

releases/agents/          (GitOps — applied by Flux)
  + qdrant-rag.yaml        → MCPServer (official server via uvx + fastembed)
  + rag-agent.yaml         → Declarative Agent using qdrant-find / qdrant-store
  ~ kustomization.yaml     → add the two files

(local, run once)
  ingest/ingest.py         → reads corpus, chunks, calls qdrant-store over MCP
  ingest/job.yaml          → optional: run ingestion as a k8s Job in-cluster
```

### 3a. Qdrant key in the `kagent` namespace (Terraform)

Secrets are namespace-scoped; the MCP server runs in `kagent`, but `qdrant-api-key` lives in `qdrant`. Add a copy in `kagent` from the same Terraform variable (don't commit it to GitOps). Append to [ai-infra/main.tf](../ai-infra/main.tf):

```hcl
resource "kubectl_manifest" "qdrant_key_kagent" {
  sensitive_fields = ["stringData.QDRANT_API_KEY"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "qdrant-api-key", namespace = "kagent" }
    type       = "Opaque"
    stringData = { QDRANT_API_KEY = var.qdrant_api_key }   # key name == env var name
  })
  depends_on = [helm_release.kagent_crds]
}
```

> The key **must** be named `QDRANT_API_KEY` because kmcp `secretRefs` injects secret keys as env vars (envFrom-style). **Verify** this semantic on your cluster (see [§7](#7-correctness-notes--gotchas)); if `secretRefs` mounts as a volume instead, use the Deployment fallback in [§8](#8-optional-enhancements).

### 3b. MCP server — `releases/agents/qdrant-rag.yaml`

Mirrors our existing `uvx` stdio pattern; non-secret config via `env`, the API key via `secretRefs`.

```yaml
apiVersion: kagent.dev/v1alpha1
kind: MCPServer
metadata:
  name: qdrant-rag
  namespace: kagent
spec:
  deployment:
    cmd: uvx
    args: ["mcp-server-qdrant"]
    port: 3000
    env:
      QDRANT_URL: "http://qdrant.qdrant.svc.cluster.local:6333"
      COLLECTION_NAME: "knowledge-base"
      EMBEDDING_PROVIDER: "fastembed"
      EMBEDDING_MODEL: "sentence-transformers/all-MiniLM-L6-v2"
      QDRANT_SEARCH_LIMIT: "5"
      FASTMCP_SERVER_HOST: "0.0.0.0"
    secretRefs:
      - qdrant-api-key          # provides QDRANT_API_KEY
  transportType: stdio
  stdioTransport: {}
```

Exposes two tools: **`qdrant-store`** (`information`, optional `metadata`) and **`qdrant-find`** (`query`). kagent auto-discovers their schemas.

### 3c. The RAG agent — `releases/agents/rag-agent.yaml`

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: rag-agent
  namespace: kagent
spec:
  type: Declarative
  description: Answers questions strictly from our knowledge base in Qdrant (RAG).
  declarative:
    modelConfig: default-model-config
    systemMessage: |-
      You are a knowledge-base assistant. Answer ONLY from retrieved context.

      # Workflow
      - For every factual question, FIRST call `qdrant-find` with a focused query.
      - Ground your answer in the returned documents. Quote/cite the source via the
        `metadata` of each result (e.g. title/source).
      - If `qdrant-find` returns nothing relevant, say "I don't have that in the
        knowledge base" — do NOT use outside knowledge or guess.
      - Use `qdrant-store` only when the user explicitly asks to save information.

      # Response format
      - Markdown. Start with the answer, then a "Sources" list from result metadata.
    tools:
      - type: McpServer
        mcpServer:
          apiGroup: kagent.dev
          kind: MCPServer
          name: qdrant-rag
          toolNames:
            - qdrant-find
            - qdrant-store
```

### 3d. Ingestion (the part that "gets the data in")

Because `mcp-server-qdrant` stores points with a **named vector + `payload.document`** schema (see [§7](#7-correctness-notes--gotchas)), the **safe** way to ingest is **through the server's own `qdrant-store` tool** — never a raw `qdrant-client` upsert (which would create a mismatched schema that `qdrant-find` can't read). Reference `ingest/ingest.py`:

```python
import asyncio, glob
from fastmcp import Client            # pip install fastmcp

MCP_URL = "http://localhost:3000/mcp" # port-forward the qdrant-rag pod, or run as in-cluster Job
CHUNK = 1000                          # ~chars; all-MiniLM truncates ~256 tokens, keep chunks small

def chunks(text, n=CHUNK, overlap=150):
    i = 0
    while i < len(text):
        yield text[i:i+n]
        i += n - overlap

async def main():
    async with Client(MCP_URL) as mcp:
        for path in glob.glob("corpus/**/*.md", recursive=True):
            text = open(path, encoding="utf-8").read()
            for j, ch in enumerate(chunks(text)):
                await mcp.call_tool("qdrant-store", {
                    "information": ch,
                    "metadata": {"source": path, "chunk": j},
                })
        print("ingest done")

asyncio.run(main())
```

Run it either by `kubectl -n kagent port-forward deploy/qdrant-rag 3000:3000` and pointing at `localhost`, or as an in-cluster `Job` (`ingest/job.yaml`) using the in-cluster URL `http://qdrant-rag.kagent.svc:3000/mcp`.

**Corpus:** start with our own docs as the knowledge base (e.g. [README.md](../README.md), [CLAUDE.md](../CLAUDE.md), [lab7/lab7.md](../lab7/lab7.md)) so retrieval is easy to sanity-check; swap in the real corpus (runbooks/product FAQ) later.

## 4. Implementation sequence

1. **Secret (Terraform):** add `qdrant_key_kagent` to `ai-infra`, then `make ai-infra-up` (or `terraform -chdir=ai-infra apply -target=kubectl_manifest.qdrant_key_kagent`).
2. **GitOps manifests:** add `releases/agents/qdrant-rag.yaml` + `releases/agents/rag-agent.yaml`, list both in [releases/agents/kustomization.yaml](../releases/agents/kustomization.yaml).
3. **Release:** `git add releases/ && git commit && git tag v0.x.y && git push origin main --tags`. The Action publishes the OCI artifact; Flux applies it. Force it now:
   ```bash
   flux reconcile source oci abox-eks-releases -n flux-system
   flux reconcile kustomization abox-eks-agents -n flux-system
   ```
4. **Confirm rollout:** `kubectl -n kagent get mcpserver qdrant-rag` and `kubectl -n kagent get agent rag-agent` (Ready), pods up.
5. **Ingest:** run `ingest.py` (port-forward or Job). First store triggers fastembed model download + auto-creates the `knowledge-base` collection.
6. **Verify** ([§6](#6-verification--demo)).

## 5. How this maps to the Gemini reference example

The linked Qdrant/Gemini guide is the canonical RAG loop: **embed → upsert with payload → embed query → search → use top-k as context**. We implement the same loop; the only substitution is **fastembed (local) instead of the Gemini Embedding API**, and the embed+upsert+search steps are handled inside `mcp-server-qdrant` and surfaced to the agent as the `qdrant-store` / `qdrant-find` tools. Net effect is identical RAG behavior with no external embedding key.

## 6. Verification / demo

```bash
# tools discovered on the server
kubectl -n kagent describe mcpserver qdrant-rag        # expect qdrant-store, qdrant-find

# collection created with the right vector size after first ingest
kubectl -n kagent port-forward svc/qdrant 6333:6333 -n qdrant &   # or curl from a debug pod
curl -s -H "api-key: $QDRANT_API_KEY" localhost:6333/collections/knowledge-base | jq '.result.config.params.vectors'
# expect size 384, distance "Cosine", and a NAMED vector key

# point count > 0 after ingest
curl -s -H "api-key: $QDRANT_API_KEY" localhost:6333/collections/knowledge-base | jq '.result.points_count'
```

Then ask `rag-agent` (via the kagent UI behind agentgateway, or `kagent` CLI) a question whose answer is **only** in the corpus. Expected: it calls `qdrant-find`, returns a grounded answer with a Sources list; for an off-corpus question it replies "I don't have that in the knowledge base."

## 7. Correctness notes / gotchas

1. **Ingest through the tool, not raw upserts.** Confirmed from source: the connector creates the collection with a **named vector** (`get_vector_name()`), **COSINE** distance, and payload `{"document": content, "metadata": {...}}`. A raw `qdrant-client.upsert` with a default/unnamed vector will **not** be found by `qdrant-find`. Use `qdrant-store` (or reuse the server's own `QdrantConnector`).
2. **Same embedding model for ingest and query** — guaranteed here because both go through the one server; if you ever change `EMBEDDING_MODEL`, you must **re-create the collection and re-ingest** (vector size/space changes).
3. **Chunk size vs model limit.** `all-MiniLM-L6-v2` truncates around ~256 tokens — keep chunks small (the snippet uses ~1000 chars w/ overlap). Oversized chunks silently lose tail content.
4. **`secretRefs` semantics** — *confirmed:* kmcp `MCPServer.secretRefs` mounts secrets as **volumes**, not env vars, and `env` is plaintext-only. `mcp-server-qdrant` reads `QDRANT_API_KEY` from the environment, so the kmcp `MCPServer` CR can't deliver it cleanly — which is why the as-built deploy uses a plain Deployment + `secretKeyRef` + `RemoteMCPServer` (see the [As-built](#-deployed--verified-as-built-2026-05-27) section).
5. **Secret namespace** — the key must exist in `kagent` (where the server runs), not only in `qdrant`. Step 3a handles this.
6. **fastembed cold start / egress** — first call downloads the ONNX model over the NAT gateway (a few seconds, one-time per pod). Pre-bake an image if cold-start latency matters.
7. **Qdrant auth** — our Qdrant has the API key enabled, so `QDRANT_API_KEY` is required; a missing/wrong key shows up as 401/403 from `qdrant-find`.

## 8. Optional enhancements

- **Better local model:** `EMBEDDING_MODEL: BAAI/bge-small-en-v1.5` (384-dim, stronger retrieval) — recreate the collection after switching.
- **OpenAI embeddings (the original idea):** swap the image to a fork that supports `EMBEDDING_PROVIDER=openai` (`text-embedding-3-small`, **1536-dim**), add an `openai-api-key` Secret, and recreate `knowledge-base` at 1536-dim. Trade-off: not the official image + per-embed API cost.
- **Deployment + `RemoteMCPServer` fallback** (full pod-spec control incl. `env.valueFrom.secretKeyRef`): run `mcp-server-qdrant --transport streamable-http` as a Deployment+Service in `kagent`, reference it from the agent via a `RemoteMCPServer` (`protocol: STREAMABLE_HTTP`, url `http://qdrant-rag.kagent.svc:8000/mcp`).
- **Resilience (ties into lab7):** add an agentgateway timeout/retry policy on the MCP route so a slow `qdrant-find` fails fast instead of hanging the agent run.
- **Quality:** add a reranking step or `QDRANT_SEARCH_LIMIT` tuning; store richer `metadata` (title/url/section) for better citations; consider multiple collections per domain.

## Verify-on-cluster checklist

- [ ] `kubectl get crd | grep mcpservers.kagent.dev` exists (kmcp controller installed).
- [ ] kmcp `MCPServer.spec.deployment` `env` + `secretRefs` behave as assumed (env injection).
- [ ] Qdrant service DNS/port (`qdrant.qdrant.svc:6333`) reachable from `kagent` ns (NetworkPolicy?).
- [ ] `knowledge-base` collection auto-created at **384-dim / Cosine** after first store.
- [ ] `rag-agent` actually invokes `qdrant-find` (check agent trace/logs).

## Sources

- Qdrant + Gemini RAG example (reference): <https://qdrant.tech/documentation/embeddings/gemini>
- Official MCP server (fastembed-only, env vars, tools, transports): <https://github.com/qdrant/mcp-server-qdrant>
- Connector storage schema (named vector / COSINE / `payload.document`): `src/mcp_server_qdrant/qdrant.py`
- kmcp `MCPServer` CRD (`deployment.env` map, `secretRefs`): <https://github.com/kagent-dev/kmcp>
- FastMCP client (ingestion): <https://gofastmcp.com>
