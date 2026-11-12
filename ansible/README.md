# Model server deployment

Ansible deployment of vLLM model servers to the Spark nodes. Run everything from this directory, so `ansible.cfg` is picked up.

Each node is independent. There is no shared state, no cross-node communication, and no load balancer. That is deliberate: a model small enough to fit one node should never be split, because NCCL collectives across the interconnect manage 3.0 GB/s and would make prefill roughly 200× slower. It also means either node can be repointed or shut down without touching the other.

## Layout

`ansible.cfg` has `host_key_checking = True` (since 2026-11-10). Every host is in `../.ssh/known_hosts`, so a host whose key changed fails to connect instead of being handed the play's secrets. After a node is rebuilt, replace its line in that file on purpose:

```bash
ssh-keygen -f ../.ssh/known_hosts -R spark-a01a.tommyslab
ssh -F ../.ssh/config -o StrictHostKeyChecking=accept-new spark1 true
```

*Host keys are recorded per address: spark1 has two entries, `spark-a01a.tommyslab` (alias `spark1`) and `100.123.96.149` (`spark1-vpn`), and a rebuild needs both replaced. `spark2-vpn` (`100.123.5.235`) has no entry yet, so its first connection must accept the key with `accept-new`.*

```
ansible.cfg               points ssh at ../.ssh/config; host keys checked
inventory.yml             spark1, spark2
group_vars/all.yml        shared defaults
host_vars/spark1.yml      what spark1 runs      <- edit these
host_vars/spark2.yml      what spark2 runs      <- edit these
roles/model_server/       model-agnostic vLLM role
roles/anythingllm/        web front end, enabled per node (retired, kept for rollback)
roles/openwebui/          web front end, enabled per node (both Sparks)
roles/bifrost/            LLM gateway in front of vLLM, enabled per node (spark1)
roles/port_allowlist/     DOCKER-USER source allowlist, shared by vLLM, Bifrost and Open WebUI
roles/tls_proxy/          nginx + Let's Encrypt (Route53 DNS-01) in front of Bifrost and Open WebUI (spark1)
roles/workspace_mcp/      Google Workspace MCP server behind Bifrost (spark1)
vars/none.yml             empty stand-in for optional .secrets files
site.yml                  the playbook
```

`host_vars/` is the seam. The role does not know or care which model it is serving; everything node-specific lives in those two files.

## Current state

| Node | Model | Served as | Port | Front end |
|---|---|---|---|---|
| spark1 | `nvidia/Qwen3.6-35B-A3B-NVFP4` | `qwen3.6-35b-a3b` | 8000 | Open WebUI at `https://openwebui.isc-spectro-sbx.click` |
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

First run takes 30–60 minutes per node: a 10 GB image pull plus 28 GB of weights. Later runs are quick, since both are cached and the play is idempotent. Weights live in `/opt/dgx-models` on each node and survive image changes and redeployment.

The playbook refuses to proceed if Docker has no `nvidia` runtime, or if less than 100 GB is free.

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

The role pulls the new weights, rewrites the unit and restarts the service. spark1 is not contacted. The old model's weights stay in the cache, so switching back costs nothing but a restart.

Note that `ms_max_model_len` is per node. A larger model needs more of the 121 GiB pool for weights and less is left for KV cache, so reduce it when moving up in size.

## Freeing spark2 entirely

```yaml
ms_enabled: false
```

```bash
ansible-playbook site.yml --limit spark2
```

Stops the service, disables it, removes the unit file and any lingering container. The node is then free for other work. The weight cache in `/opt/dgx-models` is left alone; delete it by hand if you want the disk back.

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
| `ms_image` | — | Required, and must be a pinned tag; the role refuses `:latest` |
| `ms_extra_args` | `[]` | Extra vLLM CLI flags |
| `ms_hf_token` | `""` | Only for gated repos; keep out of git |
| `ms_predownload` | `true` | Fetch weights before starting the service |

`ms_gpu_memory_utilization` behaves differently here than on a discrete GPU. GB10 shares one 121 GiB pool between CPU and GPU, so whatever vLLM reserves is taken from the host rather than from spare VRAM. 0.80 leaves about 26 GiB. Raising it toward 0.95 will start starving the OS.

Never raise `ms_tensor_parallel_size` above 1. Each node has one GPU, and tensor parallelism across nodes is the one topology this cluster handles badly.

`ms_image` has no default. A floating tag like `:latest` would be pulled by every run but only take effect at vLLM's next restart, whenever that happened to be. A pinned tag lives in the unit file, so changing it restarts vLLM on purpose.

### Source allowlist

vLLM's API keys don't cover `/invocations`, so the port itself is restricted. `roles/port_allowlist` installs a script and a oneshot unit (`vllm-firewall`, `bifrost-firewall`, `openwebui-firewall`) that put rules in Docker's `DOCKER-USER` chain: established connections, then one `RETURN` per allowed CIDR, then `DROP`, all tagged with an iptables comment (`vllm-acl`, `bifrost-acl`, `openwebui-acl`) so a rerun replaces exactly its own rules. Open WebUI joined on 2026-11-11; until then its port 3001 was open to the lab LAN, over IPv6 as well.

The allowlist can block the lab LAN but not the VPN. NetBird inserts `-A FORWARD -i wt0 -j ACCEPT` ahead of Docker's jump to `DOCKER-USER`, so traffic arriving over the VPN is accepted before these rules are reached; the `100.64.0.0/10` entries are never consulted. NetBird's own access policies decide who on the VPN gets in. To keep a port off the VPN, publish it on `127.0.0.1`, as Bifrost's port 4000 is.

The rules are IPv4 only, so the services publish on `0.0.0.0` and nothing else. Until 2026-11-10 they also listened on `[::]`, and docker-proxy carried IPv6 connections in from `172.17.0.1`, an address the allowlist trusts. Any host on the lab LAN could reach vLLM and Bifrost over link-local IPv6. After start, the play checks that:

- the port has no IPv6 listener (`ss -Hltn 'sport = :8000'`), and
- `DOCKER-USER` holds exactly one rule set (allowed CIDRs + 2).

The second check exists because the cleanup step had never matched: it looked for a quoted comment that `iptables-save` doesn't print, so every reapply stacked another set. Removing a CIDR from the list would have left its old `RETURN` rule in force.

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

Retired. spark1 ran it until 2026-11-08 and spark2 from 2026-11-06 to 2026-11-07; both now run Open WebUI (below). The role stays in `site.yml` with `allm_enabled: false`, which keeps it torn down and makes it a one-flag rollback; the data is still in `/opt/anythingllm` on both nodes. The notes below describe how it behaved while it ran.

No key needs to be entered by hand. The role takes the `anythingllm` entry from `ms_api_keys` in `.secrets/vllm-keys.yml` and writes it into the container's environment as `GENERIC_OPEN_AI_API_KEY`.

It reaches vLLM on the same host through `host.docker.internal`, mapped to the host gateway in the unit, so no IP is hardcoded and the front end survives a change of node address.

The LLM provider is pre-seeded from `host_vars`: `allm_llm_model` must match `ms_served_name`, or AnythingLLM will request a model the server does not have. `allm_llm_token_limit` defaults to 32768 rather than the model's real 262144, because AnythingLLM uses it to decide how much history and retrieved context to pack into a prompt, and a 262k prefill on this hardware looks like a hang.

The output cap is a separate setting. AnythingLLM's Generic OpenAI provider caps every reply at 1024 tokens unless `GENERIC_OPEN_AI_MAX_TOKENS` is set, on both the chat and agent paths. Qwen reasons before it answers, so 1024 tokens go on thinking and the reply stops mid-sentence with no answer. Set it through `allm_extra_env`; spark2 uses 81920, Qwen's figure for complex tasks. spark1 is still on the 1024 default.

Some AnythingLLM versions ignore `LLM_PROVIDER` from the environment and expect it set through the UI. If the provider comes up unset on first load, configure it once under Settings, AI Providers, LLM; the storage volume persists it.

State lives in `/opt/anythingllm/storage`, owned by uid 1000 because that is the container's internal user. Note this is **not** the `claude` account, which is 1001 on these nodes. `JWT_SECRET` is generated once into `/opt/anythingllm/jwt_secret` and reused, since regenerating it would invalidate every session and API key.

Embeddings use the built-in native embedder and LanceDB, both in-process, so there is no extra service to run. They do consume host memory alongside vLLM, which reserves 80% of the unified pool on spark1.

## Open WebUI

Runs on spark1 at https://openwebui.isc-spectro-sbx.click (since 2026-11-08, HTTPS since 2026-11-11, port 3001 on loopback behind nginx) and on spark2 at http://100.123.5.235:3001 (since 2026-11-07, until it is wiped), over the VPN only; the `.tommyslab` LAN names stopped working on 2026-11-11. spark1's goes through Bifrost (`https://bifrost.isc-spectro-sbx.click/v1` since 2026-11-10, virtual key `spark1-openwebui`, default model `vllm/qwen3.6-35b-a3b`), so its chats are counted per client; spark2's talks to its vLLM directly. Same shape as the AnythingLLM role: one container under a systemd unit, reaching vLLM on the host through `host.docker.internal`, enabled with `owui_enabled: true` and torn down with `owui_enabled: false`. Both roles are in `site.yml`, and a disabled one removes itself, so switching a node from one to the other is a `host_vars` change.

| Setting | Value | Why |
|---|---|---|
| Image | `ghcr.io/open-webui/open-webui:v0.13.0` | Pinned; upstream's `:main` and `:latest` track the main branch, not releases |
| Port | 3001 → 8080, IPv4 only; on spark1 published on `127.0.0.1` (`owui_publish_address`) | Same host port AnythingLLM had; spark1 is reached through `roles/tls_proxy` |
| Firewall | DOCKER-USER: loopback, Docker bridges, VPN overlay | `roles/port_allowlist` on container port 8080 (since 2026-11-11); the lab LAN is dropped |
| Data | `/opt/openwebui/data` → `/app/backend/data` | SQLite database, uploads, embedding cache |
| vLLM key | `openwebui` entry in `.secrets/vllm-keys.yml` | Its own revocable credential, shared by both instances |
| Ollama | `ENABLE_OLLAMA_API=False` | vLLM only |

*Table: Open WebUI role settings. Defaults in `roles/openwebui/defaults/main.yml`.*

The first account created in the browser becomes the admin. Later sign-ups land as `pending` until the admin approves them.

`WEBUI_SECRET_KEY` is generated once into `/opt/openwebui/webui_secret_key` and passed in. Left unset, the image's `start.sh` writes a fresh key to `/app/backend/.webui_secret_key`, which is outside the data volume, so every restart of this `--rm` container would log everyone out.

Most settings are seeded, not enforced. Open WebUI keeps the backend URL and key, sign-up, default models and most admin settings in its database. The environment only fills them in on the first launch; after that the database wins. Three keys are the exception: after every start the play runs `files/sync_connection.py` inside the container, which copies `OPENAI_API_BASE_URLS`, `OPENAI_API_KEYS` and `DEFAULT_MODELS` from the env into `openai.api_base_urls`, `openai.api_keys` and `ui.default_models`, and restarts Open WebUI if any of them changed. So changing the backend, rotating its key or renaming the default model is a `host_vars` or `.secrets` change. A connection edited in the admin UI is overwritten on the next run. Everything else still follows the database. `owui_persistent_config: false` makes the environment win for every setting, at the cost of losing all admin-UI changes on restart.

The sync exists because of a miss on 2026-11-08: spark1 was switched to Bifrost in `host_vars`, but its database had already stored the direct vLLM URL, so chats bypassed the gateway until 2026-11-09 (RUNBOOK section 24).

spark1 also forwards who sent each request (`owui_extra_env` in `host_vars/spark1.yml`). Open WebUI's user-info headers are renamed to `x-bf-lh-owui-user`, `-user-id`, `-role` and `-chat-id`, which Bifrost records as log metadata (see Bifrost below). The email header keeps its default name, which Bifrost ignores, so addresses stay out of the gateway's logs.

Open WebUI sends no `max_tokens` unless one is set in a model's parameters, so the output cap lives in vLLM instead: `max_new_tokens` in spark2's `--override-generation-config` (81920), which covers every client that leaves `max_tokens` out.

The play checks the link to the backend from inside the container, using the env's URL and key (which the sync has just made the database's too), and fails if the default model isn't listed.

## Bifrost

LLM gateway on spark1, port 4000: one OpenAI-compatible endpoint in front of the local vLLM, with a virtual key per client so token use and latency can be told apart in Grafana. Enabled with `bifrost_enabled: true` and `bifrost_vllm_model` in a node's `host_vars`; `bifrost_enabled: false` tears it down and keeps `/opt/bifrost/data`.

Clients can tag their own requests. Any `x-bf-lh-<name>` request header is stored in that request's log entry as metadata key `<name>`, with no gateway config. The tags show in the dashboard's log detail view and in `GET /api/logs/{id}`, not in the log list. They never become Prometheus labels, so high-cardinality values like user or chat ids are fine. Bifrost also records each request's `User-Agent` on its own. It does not record the client's IP address.

| Client | Header | Metadata key |
|---|---|---|
| opencode on desktop2 | `x-bf-lh-client-host: desktop2` | `client-host` |
| Open WebUI on spark1 | `x-bf-lh-owui-user`, `-user-id`, `-role`, `-chat-id` | `owui-user`, `owui-user-id`, `owui-role`, `owui-chat-id` |

*Table: per-request tags in Bifrost's logs, as of 2026-11-09.*

Headers a client already sends can be recorded too, by listing them in `bifrost_logging_headers`. They land in metadata under their own name. spark1 lists the ones opencode 2.2.6 sends with every model request:

| Header | Value | Tells you |
|---|---|---|
| `x-opencode-client` | `cli` from both the terminal and the desktop app | nothing yet; the shared background server sets it |
| `x-opencode-session`, `x-opencode-session-id`, `x-session-id`, `x-session-affinity` | `ses_…`, the same id in all four | which opencode session |
| `x-opencode-project` | 40-hex hash | which project directory |
| `traceparent`, `b3` | W3C and Zipkin trace ids | the OTel trace, for joining to traces later |

*Table: opencode headers recorded in Bifrost's metadata via `bifrost_logging_headers` on spark1.*

| Setting | Value | Why |
|---|---|---|
| Image | `maximhq/bifrost:v2.5.0` | Pinned; 2.1.0 fixed a critical unauthenticated RCE |
| Port | 4000, published on `127.0.0.1` once HTTPS is up (`bifrost_publish_address`) | Unique container port; loopback because nginx and the scraper are its only callers, and the VPN can't be filtered in `DOCKER-USER` |
| Dashboard auth | on, admin from `.secrets/bifrost.yml` | Off by default upstream, which is what made that RCE reachable |
| Inference auth | a virtual key, always | `enforce_auth_on_inference: true` |
| Backend | vLLM through `host.docker.internal:8000`, `bifrost` key | Its own revocable credential |
| Private network | `allow_private_network: true` on the vLLM provider | The Docker gateway is a 172.17.x address, which Bifrost's SSRF guard refuses by default |
| Upstream timeout | 1800 s | An 81920-token reply at ~80 tok/s takes ~17 min |
| Content logging | off | Prompts from coding tools carry code; counts and latency are still logged |
| `/metrics` | unauthenticated (`whitelisted_routes`) | Matches vLLM's; keeps the admin password out of the scraper |
| Firewall | DOCKER-USER: loopback, Docker bridges, VPN overlay | `roles/port_allowlist`, as for vLLM; IPv4 only; the lab LAN is dropped. Matters only while published on `0.0.0.0` |

*Table: Bifrost role settings. Defaults in `roles/bifrost/defaults/main.yml`.*

Configuration is a `config.json` in the data directory, rendered from `host_vars` with every secret as an `env.VAR` reference; the values are only in `/opt/bifrost/bifrost.env` (mode 0600). Bifrost writes the file into its SQLite config store on startup and keeps dashboard edits to anything the file doesn't change.

`site.yml` loads `.secrets/bifrost.yml` for every Spark, so the file must exist even on a node without Bifrost.

The play ends with a one-token request through the gateway using the first virtual key, which proves the key, the vLLM credential and the routing in one go.

## HTTPS for Bifrost and Open WebUI

`roles/tls_proxy` puts nginx on port 443 in front of local ports, one server block and certificate per entry in `tlsp_sites`. On spark1:

| Name | Upstream | Since |
|---|---|---|
| `https://bifrost.isc-spectro-sbx.click` | `127.0.0.1:4000` | 2026-11-10 |
| `https://openwebui.isc-spectro-sbx.click` | `127.0.0.1:3001` | 2026-11-11 |

*Table: HTTPS sites on spark1. Both upstream ports listen on loopback only.*

Each name is a public DNS record pointing at spark1's VPN address (`terraform/bifrost.tf`), so it only works on the VPN. The certificate comes from Let's Encrypt through a DNS-01 challenge: certbot writes a TXT record in Route53, so no port 80 and nothing public is needed. Google needs this. It refuses OAuth redirect URIs on plain HTTP or a bare IP.

| Piece | Where | Notes |
|---|---|---|
| DNS records and IAM user | `terraform/bifrost.tf` | The IAM user may write only the `_acme-challenge` TXT records for these names; a new site adds its name there first |
| Route53 key | `.secrets/acme-route53.yml`, then `/etc/letsencrypt/aws-route53-credentials` (0600) | Created by hand so the secret stays out of Terraform state |
| Certificates | `/etc/letsencrypt/live/<name>/`, one per site | `certbot.timer` renews them, with a drop-in giving it the key and a deploy hook reloading nginx |
| Sites | `/etc/nginx/sites-enabled/tls-proxy.conf`, one server block per site | IPv4 only, allowlist of loopback, Docker and VPN (the lab LAN gets 403); streaming and WebSockets on, 1800 s timeouts |

*Table: the TLS proxy. Switched on in `host_vars/spark1.yml` once the Route53 key is present.*

## Gmail through Bifrost (MCP)

Bifrost is also an MCP gateway. Clients connect to `/mcp` with a virtual key, and Bifrost passes their tool calls on to MCP servers it's configured for, logging them like model requests.

Gmail comes from `roles/workspace_mcp`, which runs the open-source [google_workspace_mcp](https://github.com/taylorwilsdon/google_workspace_mcp) server (`ghcr.io/taylorwilsdon/google_workspace_mcp:2.4.0`). It runs in external OAuth mode, read-only, with Gmail tools only. It never logs anyone in. Bifrost runs each person's Google login (`auth_type: per_user_oauth`), stores the token under that person's virtual key, and sends it as `Authorization: Bearer` with every call. The server checks the token against Google's userinfo API and reads Gmail as that person. It stores nothing (stateless mode, read-only container filesystem).

```
client ──https──▶ nginx ──▶ Bifrost /mcp ──http, Docker network "mcp"──▶ workspace-mcp ──▶ Gmail API
          (VK)                 │  per-person Google token                       (as that person)
                               └─ Google login on first use
```

*Figure: one Gmail tool call. The MCP server publishes no port; only containers on the `mcp` network reach it.*

Identity is the virtual key. Each person gets one personal key (`vk-sudobasher`), separate from the per-client keys used for model traffic. Every client that person uses sends it for MCP, so they log in to Google once, not once per client. Access is deny by default: `bifrost_vk_mcp_grants` lists which key may use which MCP connection.

| Setting | Value | Why |
|---|---|---|
| Scopes | `openid`, `userinfo.email`, `userinfo.profile`, `gmail.readonly` | Exactly what the server requires in read-only Gmail mode |
| `authorize_url` | Google's, with `access_type=offline&prompt=consent` | Without them Google issues no refresh token and logins lapse after an hour |
| `mcp_external_client_url` | `https://bifrost.isc-spectro-sbx.click` | Redirect URI becomes `<that>/api/oauth/callback`; changing it breaks stored logins |
| `mcp_enable_temp_token_auth` | `true` | Login links carry a 15-minute token, so a person without the Bifrost admin login can finish theirs |
| Server JWT key | `/opt/workspace-mcp/jwt_signing_key`, generated once | The server then doesn't need the Google client secret |

*Table: Gmail MCP settings, in `host_vars/spark1.yml` and the two roles' defaults. Switched on once `.secrets/google-oauth.yml` has a client id.*

A second Google account (for example a work account) is another entry in `_gmail_mcp_clients`, such as `gmail_work`, with the same server URL. Each connection holds its own login per key, and the tools come prefixed with the connection name. A Workspace admin may have to allow the OAuth client before a work account can log in.

## Adding a load balancer

Not included, and not recommended while both nodes run the same model only temporarily. Once the nodes diverge they serve different models and a round-robin in front of them would be wrong. If you do want one endpoint over two identical replicas, put nginx or HAProxy on the workstation with both `/v1` endpoints as upstreams; do not run it on a Spark, where it would compete for the same memory.
