# llama.cpp RPC backend

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md (canonical RPC backend doc — note the path moved from `examples/rpc/` to `tools/rpc/`; the old URL now 404s)
- **Source tree:** https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc
- **Repo:** https://github.com/ggml-org/llama.cpp (note: the canonical org is now `ggml-org`, not `ggerganov`)
- **Release tags:** https://github.com/ggml-org/llama.cpp/releases (rolling `b<NNNN>` tags)
- **Build docs:** https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
- **Server docs:** https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

## Current stable / supported version (as of 2026-05-13)

- **Latest release tag:** `b9133` (2026-05-13, per https://github.com/ggml-org/llama.cpp/releases). The project ships rolling daily-cadence tags rather than a versioned release line.
- **RPC protocol version:** **`v3.0.0`** (per `Starting RPC server v3.0.0` log line in upstream README). All `rpc-server` and main-host `--rpc` clients in a single distributed run **must speak the same protocol version**.
- **EOL policy:** none. Project explicitly labels RPC as **proof-of-concept** in the upstream README:
  > "this example and the RPC backend are currently in a proof-of-concept development stage. As such, the functionality is fragile and **insecure**. Never run the RPC server on an open network or in a sensitive environment!" — https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
- **Cluster repo references upstream issues that gate Phase 5 (3b cutover):**
  - https://github.com/ggml-org/llama.cpp/issues/17938
  - https://github.com/ggml-org/llama.cpp/issues/18882
  - https://github.com/ggml-org/llama.cpp/issues/19745
  - https://github.com/ggml-org/llama.cpp/issues/20587
  (Numbers come from `ROADMAP.md`; the audit agent should re-verify each is still open or whether any have shipped.)

## Key official best practices

- **Build flag:** `cmake .. -DGGML_CUDA=ON -DGGML_RPC=ON` on every machine that participates as a backend; `-DGGML_RPC=ON` (without CUDA) on the main/coordinator host. Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md ("Remote hosts" section).
- **GPU exposure:** `rpc-server` exposes all visible accelerators by default. Pin to a specific GPU with **`CUDA_VISIBLE_DEVICES=0`** or `--device CUDA0`. Both forms are equivalent. Source: same README.
- **Networking — never expose RPC to a non-trusted network:** the upstream README is explicit and bold: "**Never run the RPC server on an open network or in a sensitive environment!**" Bind only to LAN/VLAN. Default is `127.0.0.1:50052`. Source: same README.
- **Coordinator invocation:** `llama-cli` or `llama-server` on the main host with `--rpc <ip:port>,<ip:port>,...` and `-ngl 99` (offload as many layers as possible). Source: same README.
- **Tensor split:** by default llama.cpp distributes weights & KV cache across all available devices in proportion to free memory. Override with `--tensor-split` for explicit ratios. Source: same README.
- **Local cache (RPC server side):** `rpc-server -c` enables a local cache (default: `$HOME/.cache/llama.cpp/rpc`, override via `LLAMA_CACHE`). Strongly recommended for large models — avoids re-streaming weights over the network on every launch. Source: same README.
- **RDMA transport:** on Linux with RoCEv2-capable NICs (e.g. Mellanox ConnectX) and `libibverbs` present at build time, RPC negotiates RDMA automatically. No CLI change required. Source: same README ("RDMA transport" section).
- **Debug:** `GGML_RPC_DEBUG=1` enables verbose diagnostics on the `rpc-server`. Source: same README ("Troubleshooting").
- **Mutual exclusion with other GPU users:** `rpc-server` claims the GPU at startup. Cannot share VRAM with another running process (e.g. Petals worker) without OOM. Source: practical implication of GPU device claim, consistent with upstream README warnings.

## Canonical configuration examples

**Build (backend host):**

```bash
mkdir build-rpc-cuda
cd build-rpc-cuda
cmake .. -DGGML_CUDA=ON -DGGML_RPC=ON
cmake --build . --config Release
```

Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md.

**Backend launch (single GPU per server):**

```bash
# Pin GPU 0, listen on LAN port 50052
CUDA_VISIBLE_DEVICES=0 bin/rpc-server -p 50052 -c
```

Output (verbatim shape from upstream README):

```text
Starting RPC server v3.0.0
  endpoint       : 127.0.0.1:50052
  local cache    : n/a
Devices:
  CUDA0: NVIDIA GeForce RTX 5090 (32109 MiB, 31588 MiB free)
```

**Coordinator launch (main host):**

```bash
llama-cli -hf ggml-org/gemma-3-1b-it-GGUF -ngl 99 \
  --rpc orchestrator,orchestrator
```

Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md ("Main host" section).

## Common pitfalls / gotchas

- **Path moved.** `examples/rpc/` is gone in current `master`; the canonical path is `tools/rpc/`. Old URLs in cluster docs (`examples/rpc/...`) will 404. Source: directory layout in https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc.
- **Org renamed.** `ggerganov/llama.cpp` redirects to `ggml-org/llama.cpp`. Old GitHub issue / blob links should be updated. Source: https://github.com/ggml-org/llama.cpp.
- **Default binding is `127.0.0.1`** — must use `-H 0.0.0.0 -p 50052` (or specific LAN interface) to be reachable cross-host, but doing so removes the only line of defense per the upstream insecure-warning. Bind to a VLAN-only NIC or use a firewall. Source: README + practical experience.
- **Protocol version locks all participants.** Mixing `rpc-server v3.0.0` with a coordinator built from a different snapshot can fail to negotiate. Build all hosts from the same `b<NNNN>` tag. Source: README log line + project is a single repo with no protocol back-compat policy.
- **`rpc-server` is documented as proof-of-concept and insecure.** Production use is at the operator's risk per upstream. Source: README.
- **Mutually exclusive with Petals on the same GPU.** Both processes claim VRAM; can't run concurrently. Source: practical (GPU memory model).
- **Open issues that block 80B-A3B GGUF runs (per `ROADMAP.md`):** https://github.com/ggml-org/llama.cpp/issues/17938, /18882, /19745, /20587. Operator must verify status before tier 3b cutover.

## Authoritative URLs to cite in our docs

- https://github.com/ggml-org/llama.cpp
- https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
- https://github.com/ggml-org/llama.cpp/tree/master/tools/rpc
- https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
- https://github.com/ggml-org/llama.cpp/releases
- https://github.com/ggml-org/llama.cpp/issues/17938
- https://github.com/ggml-org/llama.cpp/issues/18882
- https://github.com/ggml-org/llama.cpp/issues/19745
- https://github.com/ggml-org/llama.cpp/issues/20587

## AUDIT CHECKLIST for the Audit Agent

1. **Path correctness:** any reference in `alfa-ai/docs/LLAMACPP_RPC_OPERATOR.md`, `deploy/llamacpp-rpc/`, or any compose file using `examples/rpc/` should be updated to `tools/rpc/`. Flag any 404-prone link.
2. **Org rename:** flag any URL in `alfa-ai/docs/` that uses `github.com/ggerganov/llama.cpp` instead of `github.com/ggml-org/llama.cpp`.
3. **Insecure-network warning:** confirm `LLAMACPP_RPC_OPERATOR.md` quotes or links the upstream "never run the RPC server on an open network" warning. Production deployment must explicitly document the LAN-only binding and the `127.0.0.1` default override.
4. **Build flag verification:** confirm every per-host build command in `deploy/llamacpp-rpc/` includes `-DGGML_CUDA=ON -DGGML_RPC=ON`. Missing `-DGGML_RPC=ON` on the coordinator silently disables RPC.
5. **Tag pinning:** confirm a specific upstream `b<NNNN>` tag is pinned (commit hash or tag in build script), not `master`. Same tag on every host (coordinator + every `rpc-server`). Cross-check `deploy/llamacpp-rpc/` build scripts and `LLAMACPP_RPC_OPERATOR.md`.
6. **GPU exclusivity:** confirm the operator runbook documents stopping Petals on each `rpc-server` host (`hub`/`orchestrator`/`gaming-c`/`gaming-a` and per-host) before starting `rpc-server`, and reverse for the 3a path. `NODE_INVENTORY.md` already calls this out — the runbook must match.
7. **Port assignment:** the cluster's tier 3b uses `:31360` for the `llama-server` coordinator on `gaming-b` and `:31351`/`:31352`/etc. for backends on `gaming-c`/`gaming-a` per `NODE_INVENTORY.md`. Confirm these don't collide with Petals (`:31330`) or Petals monitor (`:31331`) — also cross-check `PORT_ASSIGNMENTS.md`.
8. **Cache flag:** confirm every `rpc-server` is launched with `-c` and that `LLAMA_CACHE` (or default `~/.cache/llama.cpp/rpc`) lives on a persistent volume on each Windows worker (Docker Desktop / WSL2 ephemerality risk).
9. **Tensor split:** if the coordinator uses non-default `--tensor-split` (e.g. to favor `gaming-c`/`gaming-b` 12 GB cards over the 8 GB `hub`/`gaming-a`), document the exact ratios in `LLAMACPP_RPC_OPERATOR.md`.
10. **Open-issue gate:** the cluster's Phase 5 plan in `ROADMAP.md` is gated on issues #17938, #18882, #19745, #20587. Audit agent should:
    - Re-fetch each issue URL and report current state (open/closed/merged).
    - If any are closed, flag a blocker for `ROADMAP.md` to be updated.
11. **Firewall:** confirm `:31360` (coordinator) is reachable from `hub`/`apps`/`orchestrator` (any host calling LiteLLM `LLAMACPP_RPC_URL`) and that the per-host `rpc-server` ports are reachable from `gaming-b` ONLY. No host outside the LAN should reach any of these ports.
12. **Health probe:** confirm `LLAMACPP_RPC_URL` in `deploy/.env` and `deploy/litellm_config.yaml` resolves to the `llama-server` HTTP endpoint on `gaming-b`, not directly to a backend's RPC port.
