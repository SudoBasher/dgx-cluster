# Model server deployment

Ansible deployment of vLLM model servers to the Spark nodes. Run everything
from this directory, so `ansible.cfg` is picked up.

Each node is independent. There is no shared state, no cross-node
communication, and no load balancer. That is deliberate: a model small enough
to fit one node should never be split, because NCCL collectives across the
interconnect manage 3.0 GB/s and would make prefill roughly 200× slower. It
also means either node can be repointed or shut down without touching the
other.

## Layout

```
ansible.cfg               points ssh at ../.ssh/config
inventory.yml             spark1, spark2
group_vars/all.yml        shared defaults
host_vars/spark1.yml      what spark1 runs      <- edit these
host_vars/spark2.yml      what spark2 runs      <- edit these
roles/model_server/       model-agnostic vLLM role
roles/anythingllm/        web front end, enabled per node (retired, kept for rollback)
roles/openwebui/          web front end, enabled per node (both Sparks)
roles/bifrost/            LLM gateway in front of vLLM, enabled per node (spark1)
site.yml                  the playbook
```

`host_vars/` is the seam. The role does not know or care which model it is
serving; everything node-specific lives in those two files.

## Current state

| Node | Model | Served as | Port | Front end |
|---|---|---|---|---|
| spark1 | `nvidia/Qwen3.6-35B-A3B-NVFP4` | `qwen3.6-35b-a3b` | 8000 | Open WebUI on 3001 |
| spark2 | `nvidia/Qwen3.6-35B-A3B-NVFP4` | `qwen3.6-35b-a3b` | 8000 | Open WebUI on 3001; to be wiped |

Endpoints are OpenAI-compatible:

```
http://spark-a01a.tommyslab:8000/v1
http://spark-9d80.tommyslab:8000/v1
```

## Deploy

```bash
ansible-playbook site.yml                    # both nodes
ansible-playbook site.yml --limit spark1     # one node
ansible-playbook site.yml --check --diff     # preview
```

First run takes 30–60 minutes per node: a 10 GB image pull plus 28 GB of
weights. Later runs are quick, since both are cached and the play is
idempotent. Weights live in `/opt/dgx-models` on each node and survive image
changes and redeployment.

The playbook refuses to proceed if Docker has no `nvidia` runtime, or if less
than 100 GB is free.

## Running a different model on spark2

Edit `host_vars/spark2.yml`:

```yaml
ms_enabled: true
ms_model_repo: stepfun-ai/Step-3.7-Flash
ms_served_name: step-3.7-flash
ms_max_model_len: 131072
```

Then:

```bash
ansible-playbook site.yml --limit spark2
```

The role pulls the new weights, rewrites the unit and restarts the service.
spark1 is not contacted. The old model's weights stay in the cache, so
switching back costs nothing but a restart.

Note that `ms_max_model_len` is per node. A larger model needs more of the
121 GiB pool for weights and less is left for KV cache, so reduce it when
moving up in size.

## Freeing spark2 entirely

```yaml
ms_enabled: false
```

```bash
ansible-playbook site.yml --limit spark2
```

Stops the service, disables it, removes the unit file and any lingering
container. The node is then free for other work. The weight cache in
`/opt/dgx-models` is left alone; delete it by hand if you want the disk back.

To bring it back, set `ms_enabled: true` and re-run.

## Useful variables

Set in `host_vars/<node>.yml` to override `group_vars/all.yml`.

| Variable | Default | Notes |
|---|---|---|
| `ms_enabled` | `true` | `false` tears the service down |
| `ms_model_repo` | — | Hugging Face repo id; required when enabled |
| `ms_served_name` | repo basename | The name clients pass as `model` |
| `ms_max_model_len` | `262144` | Reduce for larger models |
| `ms_port` | `8000` | Change to run two services on one node |
| `ms_gpu_memory_utilization` | `0.80` | See below |
| `ms_image` | `vllm/vllm-openai:latest` | Pin a tag for reproducibility |
| `ms_extra_args` | `[]` | Extra vLLM CLI flags |
| `ms_hf_token` | `""` | Only for gated repos; keep out of git |
| `ms_predownload` | `true` | Fetch weights before starting the service |

`ms_gpu_memory_utilization` behaves differently here than on a discrete GPU.
GB10 shares one 121 GiB pool between CPU and GPU, so whatever vLLM reserves is
taken from the host rather than from spare VRAM. 0.80 leaves about 26 GiB.
Raising it toward 0.95 will start starving the OS.

Never raise `ms_tensor_parallel_size` above 1. Each node has one GPU, and
tensor parallelism across nodes is the one topology this cluster handles badly.

## Operations

```bash
# status and logs
ansible sparks -b -m command -a "systemctl status vllm --no-pager"
ansible spark1 -b -m command -a "journalctl -u vllm -n 100 --no-pager"

# restart
ansible sparks -b -m systemd -a "name=vllm state=restarted"

# what is each node serving
ansible sparks -m uri -a "url=http://127.0.0.1:8000/v1/models return_content=yes"
```

Smoke test:

```bash
curl -s http://spark-a01a.tommyslab:8000/v1/chat/completions \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $KEY" \
  -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

## AnythingLLM

Retired. spark1 ran it until 2026-11-08 and spark2 from 2026-11-06 to
2026-11-07; both now run Open WebUI (below). The role stays in `site.yml`
with `allm_enabled: false`, which keeps it torn down and makes it a one-flag
rollback; the data is still in `/opt/anythingllm` on both nodes. The notes
below describe how it behaved while it ran.

No key needs to be entered by hand. The role takes the `anythingllm` entry from
`ms_api_keys` in `.secrets/vllm-keys.yml` and writes it into the container's
environment as `GENERIC_OPEN_AI_API_KEY`.

It reaches vLLM on the same host through `host.docker.internal`, mapped to the
host gateway in the unit, so no IP is hardcoded and the front end survives a
change of node address.

The LLM provider is pre-seeded from `host_vars`: `allm_llm_model` must match
`ms_served_name`, or AnythingLLM will request a model the server does not have.
`allm_llm_token_limit` defaults to 32768 rather than the model's real 262144,
because AnythingLLM uses it to decide how much history and retrieved context to
pack into a prompt, and a 262k prefill on this hardware looks like a hang.

The output cap is a separate setting. AnythingLLM's Generic OpenAI provider
caps every reply at 1024 tokens unless `GENERIC_OPEN_AI_MAX_TOKENS` is set,
on both the chat and agent paths. Qwen reasons before it answers, so 1024
tokens go on thinking and the reply stops mid-sentence with no answer. Set it
through `allm_extra_env`; spark2 uses 81920, Qwen's figure for complex tasks.
spark1 is still on the 1024 default.

Some AnythingLLM versions ignore `LLM_PROVIDER` from the environment and expect
it set through the UI. If the provider comes up unset on first load, configure
it once under Settings, AI Providers, LLM; the storage volume persists it.

State lives in `/opt/anythingllm/storage`, owned by uid 1000 because that is the
container's internal user. Note this is **not** the `claude` account, which is
1001 on these nodes. `JWT_SECRET` is generated once into
`/opt/anythingllm/jwt_secret` and reused, since regenerating it would invalidate
every session and API key.

Embeddings use the built-in native embedder and LanceDB, both in-process, so
there is no extra service to run. They do consume host memory alongside vLLM,
which reserves 80% of the unified pool on spark1.

## Open WebUI

Runs on spark1 at http://spark-a01a.tommyslab:3001 (since 2026-11-08) and on
spark2 at http://spark-9d80.tommyslab:3001 (since 2026-11-07, until it is
wiped). spark1's goes through Bifrost (`http://host.docker.internal:4000/v1`,
virtual key `spark1-openwebui`, default model `vllm/qwen3.6-35b-a3b`), so its
chats are counted per client; spark2's talks to its vLLM directly. Same shape as the AnythingLLM role: one container under a
systemd unit, reaching vLLM on the host through `host.docker.internal`, enabled
with `owui_enabled: true` and torn down with `owui_enabled: false`. Both roles
are in `site.yml`, and a disabled one removes itself, so switching a node from
one to the other is a `host_vars` change.

| Setting | Value | Why |
|---|---|---|
| Image | `ghcr.io/open-webui/open-webui:v0.13.0` | Pinned; upstream's `:main` and `:latest` track the main branch, not releases |
| Port | 3001 → 8080 | Same host port AnythingLLM had, so the URL didn't change |
| Data | `/opt/openwebui/data` → `/app/backend/data` | SQLite database, uploads, embedding cache |
| vLLM key | `openwebui` entry in `.secrets/vllm-keys.yml` | Its own revocable credential, shared by both instances |
| Ollama | `ENABLE_OLLAMA_API=False` | vLLM only |

*Table: Open WebUI role settings. Defaults in `roles/openwebui/defaults/main.yml`.*

The first account created in the browser becomes the admin. Later sign-ups
land as `pending` until the admin approves them.

`WEBUI_SECRET_KEY` is generated once into `/opt/openwebui/webui_secret_key`
and passed in. Left unset, the image's `start.sh` writes a fresh key to
`/app/backend/.webui_secret_key`, which is outside the data volume, so every
restart of this `--rm` container would log everyone out.

Most settings are seeded, not enforced. Open WebUI keeps the vLLM URL and key,
sign-up, default models and most admin settings in its database. The
environment only fills them in on the first launch; after that the database
wins and editing the role changes nothing. To rotate the vLLM key, change it in
the admin UI (Settings, Connections) as well as in `.secrets`, or set
`owui_persistent_config: false` to make the environment win on every start at
the cost of losing admin-UI changes on restart.

Open WebUI sends no `max_tokens` unless one is set in a model's parameters, so
the output cap lives in vLLM instead: `max_new_tokens` in spark2's
`--override-generation-config` (81920), which covers every client that leaves
`max_tokens` out.

The play checks the link to vLLM from inside the container, using the URL and
key Open WebUI was actually given, and fails if the default model isn't listed.

## Bifrost

LLM gateway on spark1, port 4000: one OpenAI-compatible endpoint in front of
the local vLLM, with a virtual key per client so token use and latency can be
told apart in Grafana. Enabled with `bifrost_enabled: true` and
`bifrost_vllm_model` in a node's `host_vars`; `bifrost_enabled: false` tears
it down and keeps `/opt/bifrost/data`.

| Setting | Value | Why |
|---|---|---|
| Image | `maximhq/bifrost:v2.5.0` | Pinned; 2.1.0 fixed a critical unauthenticated RCE |
| Port | 4000, published and listened on | Unique container port, so its firewall rule can't catch Open WebUI's internal 8080 |
| Dashboard auth | on, admin from `.secrets/bifrost.yml` | Off by default upstream, which is what made that RCE reachable |
| Inference auth | a virtual key, always | `enforce_auth_on_inference: true` |
| Backend | vLLM through `host.docker.internal:8000`, `bifrost` key | Its own revocable credential |
| Private network | `allow_private_network: true` on the vLLM provider | The Docker gateway is a 172.17.x address, which Bifrost's SSRF guard refuses by default |
| Upstream timeout | 1800 s | An 81920-token reply at ~80 tok/s takes ~17 min |
| Content logging | off | Prompts from coding tools carry code; counts and latency are still logged |
| `/metrics` | unauthenticated (`whitelisted_routes`) | Matches vLLM's; keeps the admin password out of the scraper |
| Firewall | DOCKER-USER: loopback, Docker bridges, VPN overlay | Same model as vLLM's; the lab LAN is dropped |

*Table: Bifrost role settings. Defaults in `roles/bifrost/defaults/main.yml`.*

Configuration is a `config.json` in the data directory, rendered from
`host_vars` with every secret as an `env.VAR` reference; the values are only in
`/opt/bifrost/bifrost.env` (mode 0600). Bifrost writes the file into its SQLite
config store on startup and keeps dashboard edits to anything the file doesn't
change.

`site.yml` loads `.secrets/bifrost.yml` for every Spark, so the file must exist
even on a node without Bifrost.

The play ends with a one-token request through the gateway using the first
virtual key, which proves the key, the vLLM credential and the routing in one
go.

## Adding a load balancer

Not included, and not recommended while both nodes run the same model only
temporarily. Once the nodes diverge they serve different models and a
round-robin in front of them would be wrong. If you do want one endpoint over
two identical replicas, put nginx or HAProxy on the workstation with both
`/v1` endpoints as upstreams; do not run it on a Spark, where it would compete
for the same memory.
