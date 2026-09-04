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
| spark1 (`spark-a01a`) | `100.123.96.149` | GPU node, vLLM + AnythingLLM | sparks |
| spark2 (`spark-9d80`) | `100.123.5.235` | GPU node, vLLM | sparks |
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

## Web interfaces

| Service | URL | Notes |
|---|---|---|
| Grafana | http://100.123.229.83:3000 | metrics and log exploration; login `admin`, password in `.secrets/grafana.yml` |
| NetBird dashboard | https://vpn.isc-spectro-sbx.click | the only public endpoint |
| AnythingLLM | http://100.123.96.149:3001 | spark1 only |
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
