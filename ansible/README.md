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
roles/anythingllm/        web front end, enabled per node
site.yml                  the playbook
```

`host_vars/` is the seam. The role does not know or care which model it is
serving; everything node-specific lives in those two files.

## Current state

| Node | Model | Served as | Port | Front end |
|---|---|---|---|---|
| spark1 | `Qwen/Qwen3.8-27B-FP8` | `qwen3.8-27b` | 8000 | AnythingLLM on 3001 |
| spark2 | `Qwen/Qwen3.8-27B-FP8` | `qwen3.8-27b` | 8000 | — |

Endpoints are OpenAI-compatible:

```
http://spark-a01a.local:8000/v1
http://spark-9d80.local:8000/v1
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
curl -s http://spark-a01a.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

## AnythingLLM

Runs on spark1 only, at http://spark-a01a.local:3001. Enabled with
`allm_enabled: true` in `host_vars/spark1.yml`; set `allm_enabled: false` and
re-run to remove it.

It reaches vLLM on the same host through `host.docker.internal`, mapped to the
host gateway in the unit, so no IP is hardcoded and the front end survives a
change of node address.

The LLM provider is pre-seeded from `host_vars`: `allm_llm_model` must match
`ms_served_name`, or AnythingLLM will request a model the server does not have.
`allm_llm_token_limit` defaults to 32768 rather than the model's real 262144,
because AnythingLLM uses it to decide how much history and retrieved context to
pack into a prompt, and a 262k prefill on this hardware looks like a hang.

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
which has already reserved 80% of the unified pool.

## Adding a load balancer

Not included, and not recommended while both nodes run the same model only
temporarily. Once the nodes diverge they serve different models and a
round-robin in front of them would be wrong. If you do want one endpoint over
two identical replicas, put nginx or HAProxy on the workstation with both
`/v1` endpoints as upstreams; do not run it on a Spark, where it would compete
for the same memory.
