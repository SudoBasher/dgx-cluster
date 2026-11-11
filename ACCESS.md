# Access

Everything is reachable over the NetBird VPN. Nothing in AWS has a public
endpoint except the VPN control plane itself.

Connect first, then use the addresses below from anywhere.

## Joining the VPN

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --management-url https://vpn.isc-spectro-sbx.click --setup-key <KEY>
```

Setup keys are per-role and reusable, listed in the NetBird dashboard under
Setup Keys. Use `admin-device` for your own machines, `teammate-device` for
others. Clients exist for Linux, macOS, iOS, Android and Windows.

Check state with `netbird status`.

## Overlay addresses

These are stable NetBird addresses in `100.123.0.0/16`. They do not change when
a node's LAN address does, which is why they are the preferred way in.

| Host | Overlay IP | Role | Groups |
|---|---|---|---|
| humans | `some ips` | workstation | admins |
| spark1 (`spark-a01a`) | `100.123.96.149` | GPU node, vLLM + Open WebUI | sparks |
| spark2 (`spark-9d80`) | `100.123.5.235` | GPU node, vLLM + Open WebUI; to be wiped | sparks |
| obs-write | `100.123.158.113` | Thanos receive/compact, Loki | aws-infra |
| obs-read | `100.123.229.83` | Thanos query/store, Grafana | aws-infra, obs-read |
| netbird-cp | — | control plane, reached by DNS | — |

## SSH

Two different accounts and keys: the Sparks use `claude`, the AWS nodes use
`ubuntu`. The repo SSH config has aliases for both, over LAN and over VPN.

```bash
ssh -F .ssh/config spark1          # over the lab LAN, needs eno2 up
ssh -F .ssh/config spark1-vpn      # over the VPN, works from anywhere
ssh -F .ssh/config obs-read        # AWS, over the VPN
ssh -F .ssh/config netbird-cp      # AWS control plane, public DNS
```

Direct, without the config file:

```bash
ssh -i .ssh/dgx_spark claude@100.123.96.149     # spark1
ssh -i .ssh/dgx_spark claude@100.123.5.235      # spark2
ssh -i .ssh/aws_dgx   ubuntu@100.123.158.113    # obs-write
ssh -i .ssh/aws_dgx   ubuntu@100.123.229.83     # obs-read
```

Private keys live in `.ssh/` in this repository, not `~/.ssh`, and are
gitignored.

Service credentials live in `.secrets/`, also gitignored, and are loaded by the
playbooks through `vars_files`:

| File | Holds |
|---|---|
| `.secrets/grafana.yml` | `obs_grafana_admin_password` |
| `.secrets/vllm-keys.yml` | `ms_api_keys`, one per client |
| `.secrets/netbird-keys.yml` | per-group setup keys |
| `.secrets/netbird-token` | NetBird API personal access token |

## Pointing a client at the gateway

Coding tools and other OpenAI-compatible clients should go through Bifrost
rather than straight to vLLM, so their usage shows up per client in Grafana.

| Setting | Value |
|---|---|
| Base URL | `https://bifrost.isc-spectro-sbx.click/v1` (VPN only: the name points at spark1's overlay address; the lab LAN gets 403) |
| Model | `vllm/qwen3.6-35b-a3b` |
| API key | that client's `bifrost_virtual_keys` value in `.secrets/bifrost.yml`, sent as `Authorization: Bearer` |

*Table: gateway connection settings. `/openai/v1` also works as a base URL,
but it did not pass `chat_template_kwargs` through in testing; `/v1` did.*

One virtual key per client. To add one, append an entry with a new `id`, a
`name` and a `value` starting with `sk-bf-` to `bifrost_virtual_keys`, then run
`ansible-playbook site.yml --limit spark1`. Two exist today:
`desktop2-opencode` and `spark1-openwebui`.

### opencode (terminal and desktop app)

Tested with opencode 2.2.6 on desktop2. One global file serves both: every
local opencode client talks to a shared background server, which reads
`~/.config/opencode/opencode.jsonc`. The key goes in the file itself rather
than `{env:...}`, because the desktop app, started from the desktop rather
than a shell, doesn't inherit shell variables.

```bash
mkdir -p ~/.config/opencode
VK=$(python3 -c "import yaml;print([k for k in yaml.safe_load(open('.secrets/bifrost.yml'))['bifrost_virtual_keys'] if k['name']=='desktop2-opencode'][0]['value'])")
# MCP uses the person's key, not the client's: Bifrost files Google logins under it.
MCP_VK=$(python3 -c "import yaml;print([k for k in yaml.safe_load(open('.secrets/bifrost.yml'))['bifrost_virtual_keys'] if k['name']=='sudobasher'][0]['value'])")
cat > ~/.config/opencode/opencode.jsonc <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "bifrost/vllm/qwen3.6-35b-a3b",
  "providers": {
    "bifrost": {
      "name": "Bifrost (spark1)",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "https://bifrost.isc-spectro-sbx.click/v1", "apiKey": "$VK" },
      "headers": { "x-bf-lh-client-host": "$(hostname)" },
      "models": {
        "vllm/qwen3.6-35b-a3b": {
          "name": "Qwen3.6 35B A3B (spark1)",
          "capabilities": { "tools": true, "input": ["text"], "output": ["text"] },
          "limit": { "context": 262144, "output": 81920 }
        }
      }
    }
  },
  "mcp": {
    "servers": {
      "bifrost": {
        "type": "remote",
        "url": "https://bifrost.isc-spectro-sbx.click/mcp",
        "oauth": false,
        "headers": { "x-bf-vk": "$MCP_VK" },
        "codemode": false
      }
    }
  }
}
EOF
chmod 600 ~/.config/opencode/opencode.jsonc
opencode service restart          # the background server reads config at start
opencode models | grep bifrost    # bifrost/vllm/qwen3.6-35b-a3b
```

The provider id must not be `vllm`, `ollama` or `lmstudio`; opencode treats
those as local runtimes and tries to discover them. A model key containing `/`
works: the provider id ends at the first slash, so `bifrost/vllm/qwen3.6-35b-a3b`
is provider `bifrost`, model `vllm/qwen3.6-35b-a3b`. Requests show up in
Bifrost as `app=OpenCode`, user agent `opencode/latest/2.2.6/cli`, with
metadata `client-host` set from the `headers` line. The `mcp.servers.bifrost`
entry gives opencode the Gmail tools Bifrost grants to `vk-sudobasher`.
`codemode: false` exposes them as plain tool calls instead of opencode's Code
Mode, which asks the model to write code that calls them. Bifrost doesn't log the
client's IP, so that header is the only record of which machine sent a
request. Any `x-bf-lh-<name>` header works the same way, so other clients can
tag themselves too; see the Bifrost section of `ansible/README.md`.

### LM Studio

Can't be pointed at the gateway. LM Studio's documentation covers it only as a
local model runner and server (`http://localhost:1234/v1`) and LM Link between
LM Studio installs. Nothing documents using a remote OpenAI-compatible endpoint
as its chat backend, and no plugin for it turned up (checked 2026-11-08). Chats
in LM Studio run on desktop2's own hardware and never reach Bifrost.


## Web interfaces

| Service | URL | Notes |
|---|---|---|
| Grafana | http://100.123.229.83:3000 | metrics and log exploration; login `admin`, password in `.secrets/grafana.yml` |
| NetBird dashboard | https://vpn.isc-spectro-sbx.click | the only public endpoint |
| Open WebUI (spark1) | http://100.123.96.149:3001 | uses `qwen3.6-35b-a3b`; first account created is the admin; VPN only, the lab LAN is blocked |
| Open WebUI (spark2) | http://100.123.5.235:3001 | same as spark1; goes away when spark2 is wiped |
| Bifrost gateway (spark1) | https://bifrost.isc-spectro-sbx.click | OpenAI-compatible at `/v1`, MCP at `/mcp`; per-client virtual key; dashboard login in `.secrets/bifrost.yml`. Port 4000 listens on spark1's loopback only, so HTTPS is the only way in |
| vLLM (spark1) | http://100.123.96.149:8000/v1 | OpenAI-compatible; requires a key |
| vLLM (spark2) | http://100.123.5.235:8000/v1 | OpenAI-compatible; requires a key |
| Thanos Query | http://100.123.229.83:19192 | raw PromQL, debugging |
| Loki | http://100.123.158.113:3100 | queried through Grafana |

The DGX Dashboard on each Spark binds to loopback only, so it still needs a
tunnel, but the tunnel can now run over the VPN:

```bash
ssh -F .ssh/config -f -N -L 11001:127.0.0.1:11000 spark1-vpn
ssh -F .ssh/config -f -N -L 11002:127.0.0.1:11000 spark2-vpn
```

## Calling the model servers

Both nodes require a bearer token on `/v1`. Keys are per-client and listed in
`.secrets/vllm-keys.yml`.

```bash
KEY=$(python3 -c "import yaml;print([c['key'] for c in
  yaml.safe_load(open('.secrets/vllm-keys.yml'))['ms_api_keys']
  if c['name']=='admin-tommy'][0])")

curl -H "Authorization: Bearer $KEY" http://100.123.96.149:8000/v1/models
```

The published port only accepts the VPN overlay, the Docker bridges, the
interconnect and loopback. **Both Ethernet networks are blocked**, so a client
on the lab LAN must join the VPN rather than using `spark-a01a.tommyslab:8000`.
Open WebUI's port 3001 is restricted the same way.
Widen `ms_allowed_cidrs` in `roles/model_server/defaults/main.yml` if that is
not what you want.

## Who can reach what

| Group | Sparks | Lab VLAN | AWS |
|---|---|---|---|
| admins | everything | everything | everything |
| teammates | everything | everything | Grafana only, TCP 3000 |

Teammates get full lab access and exactly one port in the cloud. The policy
targets the `obs-read` peer specifically, not the whole `aws-infra` group, so
obs-write and the control plane stay out of reach.

## Connection quality

`netbird status -d` reports `Connection type` and the ICE candidate pair for
each peer.

| Pair | Type | ICE candidates | Latency |
|---|---|---|---|
| spark1 - spark2 - desktop2 | P2P | `host/prflx` | 0.36 ms |
| sparks - obs-write | P2P | `srflx/srflx` | 32 ms |

**All links are direct.** Spark-to-AWS was relayed through coturn at 82 ms
until the observability nodes were given Elastic IPs; it is now a direct
`srflx/srflx` tunnel at 32 ms, matching the ~30 ms the design predicted.
netbird-cp is no longer in the telemetry data path.

Peers show `Idle` with no candidate pair until first traffic. That is lazy
connection setup, not a fault; obs-read usually sits idle from a Spark because
the Sparks push to obs-write and never initiate to obs-read.

Sparks do not peer with each other over the VPN. There is no `sparks-to-sparks`
policy because they already share the LAN and the 200GbE cable, so the overlay
would only add a hop.

## Verifying access

```bash
netbird status -d                      # your own peer state
curl -s http://100.123.229.83:3000/api/health     # Grafana, expect database ok
```

Whole-fleet scrape health, which is the fastest single check that telemetry is
flowing from both Sparks:

```bash
curl -s --get http://100.123.229.83:19192/api/v1/query \
  --data-urlencode 'query=sum(up)'
```

Expect `18`. Anything less means a target is down; break it out by `node` and
`job` to find which.
