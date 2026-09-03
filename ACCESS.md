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
| desktop2 | `100.123.254.66` | workstation | admins |
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

## Web interfaces

| Service | URL | Notes |
|---|---|---|
| Grafana | http://100.123.229.83:3000 | metrics and log exploration |
| NetBird dashboard | https://vpn.isc-spectro-sbx.click | the only public endpoint |
| AnythingLLM | http://100.123.96.149:3001 | spark1 only |
| vLLM (spark1) | http://100.123.96.149:8000/v1 | OpenAI-compatible |
| vLLM (spark2) | http://100.123.5.235:8000/v1 | OpenAI-compatible |
| Thanos Query | http://100.123.229.83:19192 | raw PromQL, debugging |
| Loki | http://100.123.158.113:3100 | queried through Grafana |

The DGX Dashboard on each Spark binds to loopback only, so it still needs a
tunnel, but the tunnel can now run over the VPN:

```bash
ssh -F .ssh/config -f -N -L 11001:127.0.0.1:11000 spark1-vpn
ssh -F .ssh/config -f -N -L 11002:127.0.0.1:11000 spark2-vpn
```

## Who can reach what

| Group | Sparks | Lab VLAN | AWS |
|---|---|---|---|
| admins | everything | everything | everything |
| teammates | everything | everything | Grafana only, TCP 3000 |

Teammates get full lab access and exactly one port in the cloud. The policy
targets the `obs-read` peer specifically, not the whole `aws-infra` group, so
obs-write and the control plane stay out of reach.

## Connection quality

`netbird status -d` reports whether each peer pair is `Direct` or `Relayed`.

Spark-to-AWS is currently **Relayed**: NAT traversal fails through the UniFi
Dream Machine, so that traffic transits coturn on netbird-cp. It works, and
telemetry volume is small, but it adds latency (measured 82 ms average against
roughly 30 ms expected direct) and puts the control-plane node in the data
path.

Peers show `Idle` until first traffic. That is lazy connection setup, not a
fault.

## Known gaps

The lab VLAN `10.255.128.0/20` is **not yet advertised** as a NetBird route.
`nbc_routes` is set in host_vars but the role does not create routes through
the API, so hosts on the lab network that cannot run a client are currently
unreachable over the VPN. The Sparks themselves are reachable at their overlay
addresses regardless.

The `All -> All` default policy is still enabled, so the group policies above
are defined but not yet binding.
