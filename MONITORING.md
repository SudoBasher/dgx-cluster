# Monitoring

Every command here has been run against the live nodes. Tooling is installed by
`RUNBOOK.md` section 8; if something reports "command not found", that section
has not been replayed on that node.

Two layers. **Grafana** is the day-to-day interface, holding 12 months of
history. The CLI tools below are for the live view and for when Grafana itself
is the thing that is broken.

All addresses are NetBird overlay addresses and require the VPN. See
`ACCESS.md`.

## Grafana

<http://100.123.229.83:3000>

Metrics come from Thanos, logs from Loki, both provisioned as datasources with
fixed uids (`thanos`, `loki`).

Three dashboards ship with the deployment. They are provisioned from
`ansible/roles/observability/files/dashboards/`, so a playbook run restores
them and also overwrites any browser edits.

| Dashboard | What it answers |
|---|---|
| **vLLM and Qwen performance** | Is inference fast, and if not, why. Tokens/s, time to first token, inter-token latency, KV cache pressure, preemptions, prefix cache hit rate, plus GPU temperature and power on the same time axis |
| **Fleet health** | Are the nodes healthy. CPU, unified memory, root filesystem, GPU utilisation and thermals, 200GbE interconnect throughput, and SSH authentication events (a Security row covering both Sparks and the NetBird control plane) |
| **Observability stack health** | Is the telemetry pipeline itself healthy. Samples accepted/s, remote-write queue depth, dropped telemetry, compactor iterations and memory, query p95 |

Start at **Observability stack health** when a dashboard looks wrong. A flat
line is far more often a dropped scrape or a stalled remote-write queue than
an actual change on the node.

**Logs.** Explore, pick Loki, then filter by systemd unit:

```logql
{service_name="vllm.service"}
{service_name="anythingllm.service"} |= "error"
{node="spark1"} | json | priority <= 3
{service_name="ssh.service"} |= "Accepted"          # successful logins, any host
{service_name="ssh.service"} |= "Failed"            # rejected attempts, any host
{service_name="netbird-server"}                     # NetBird's own auth/peer activity
```

Two different things called "auth" here, kept as separate services rather than
merged:

- `ssh.service` is host login — who got a shell on a Spark or on netbird-cp.
- `netbird-server` is the VPN's own management service — peer connections,
  relay activity, and the JWT/Dex authentication behind the dashboard and API.

Both live on the Fleet health dashboard's Security row as three panels, not
two: SSH on the Sparks, SSH on netbird-cp, and VPN auth from netbird-server
itself. `netbird-dashboard` and `netbird-traefik` are also visible as their
own services in Explore if the underlying HTTP traffic is ever worth
inspecting, though nothing is provisioned against them yet.

Kernel messages carry no unit and land under `unknown_service`.

Streams carry three labels: `service_name`, `node` and `host_name`. Only
`service_name` existed until 2026-09-04 — Loki's OTLP endpoint promotes a fixed
default set of resource attributes and `node` was not among them, so
`{node="spark1"}` silently matched nothing. Logs written before that date still
have no `node` label.

**Who is calling the model servers.** vLLM logs every request with its source
address, and NetBird overlay addresses are stable per peer, so an address
identifies a machine:

```logql
sum by (ip) (count_over_time(
  {service_name="vllm.service"} |= "HTTP/1.1"
  | regexp `(?P<ip>[0-9.]+):(?P<cport>[0-9]+) - "(?P<method>[A-Z]+) (?P<path>[^ ]+) HTTP/[0-9.]+" (?P<status>[0-9]+)`
  | path =~ "/v1/.*|/invocations" [1h]))
```

Filter to `| status = "401"` to see rejected callers. The **Clients** row of the
vLLM dashboard runs exactly this. Exclude `/metrics` or the collector's own
scrapes dominate the count by three orders of magnitude.

**Metrics.** Explore, pick Thanos. Useful starting points:

```promql
vllm:kv_cache_usage_perc                          # near 1.0 means preemption
vllm:num_requests_waiting                         # above 0 means saturated
rate(vllm:generation_tokens_total[1m])            # real tokens/s
DCGM_FI_DEV_GPU_TEMP                              # per-GPU temperature
node_memory_MemAvailable_bytes / 1024^3           # unified pool headroom
rate(node_ethtool_transmitted_bytes_phy{device="enp1s0f0np0"}[1m])*8   # interconnect bits/s
```

Retention is tiered automatically: raw 1s for 30 days, 5-minute rollups for 12
months, 1-hour for 3 years. Thanos picks the resolution per query, so a
year-long dashboard stays fast.

## Node labels

Three labels identify a host, and only one works everywhere.

| Label | Example | Set on |
|---|---|---|
| `node` | `spark1` | every job |
| `host_name` | `spark-a01a` | every job |
| `Hostname` | `spark-a01a` | DCGM only |

Filter on `host_name` or `node`. Filtering on `Hostname` silently matches DCGM
alone, which looks like the other exporters are not shipping when they are.

Host metrics, all `node_exporter`:

```promql
100 - avg(rate(node_cpu_seconds_total{host_name="spark-a01a",mode="idle"}[1m]))*100
node_memory_MemAvailable_bytes{host_name="spark-a01a"}
rate(node_network_receive_bytes_total{host_name="spark-a01a",device="enP7s7"}[1m])*8
rate(node_ethtool_transmitted_bytes_phy{host_name="spark-a01a",device="enp1s0f0np0"}[1m])*8
rate(node_disk_read_bytes_total{host_name="spark-a01a"}[1m])
node_load1{host_name="spark-a01a"}
```

`node_memory_*` is the only meaningful memory view on GB10. CPU and GPU share
one 121 GiB pool, so DCGM reports nothing useful for GPU memory and stock
NVIDIA dashboards show empty VRAM panels.

## Setup

Two aliases, one for pipeable streams and one for interactive tools that need a
TTY. Put both in your shell rc.

```bash
export DGX="ssh    -F /home/user/storage/development/github/sudobasher/dgx-cluster/.ssh/config"
# Use spark1-vpn / spark2-vpn in place of spark1 / spark2 to go over the VPN.
export DGXT="ssh -t -F /home/user/storage/development/github/sudobasher/dgx-cluster/.ssh/config"
```

## Web dashboards

Each node runs NVIDIA DGX Dashboard (`dgx-dashboard.service`) on
127.0.0.1:11000, bound to loopback and unreachable without a tunnel.

```bash
ssh -F .ssh/config -f -N -o ExitOnForwardFailure=yes -L 11001:127.0.0.1:11000 spark1-vpn
ssh -F .ssh/config -f -N -o ExitOnForwardFailure=yes -L 11002:127.0.0.1:11000 spark2-vpn
```

The `-vpn` aliases go over the overlay, so these work from anywhere and do not
depend on the workstation's lab interface being up.

| Node | URL |
|---|---|
| spark1 (`spark-a01a`) | http://localhost:11001 |
| spark2 (`spark-9d80`) | http://localhost:11002 |

Tunnels do not survive a reboot or a network change.

```bash
ss -ltn | grep -E '1100[12]'                       # bound means alive
pgrep -af 'L 1100[12]:127.0.0.1:11000'
kill $(pgrep -f 'L 1100[12]:127.0.0.1:11000')
```

There is also a `dgx-dashboard-admin.service`, but it exposes no TCP port. Port
11000 is the only listener besides sshd and cups.

## Interactive tools

| Command | Purpose |
|---|---|
| `$DGXT spark1 nvtop` | GPU utilisation, temperature, power, clocks, per-process attribution |
| `$DGXT spark1 btop` | CPU, memory, disk, network, processes in one screen |
| `$DGXT spark1 htop` | Process list |
| `$DGXT spark1 glances` | Broadest single view, including sensors and containers |
| `$DGXT spark1 bmon` | Per-interface bandwidth with sparklines |
| `$DGXT spark1 nload` | Simple in/out bandwidth graph |
| `$DGXT spark1 'sudo iftop -i enp1s0f0np0'` | Per-connection bandwidth; needs root, binary in `/usr/sbin` |

## GPU

One node:

```bash
$DGX spark1 'nvidia-smi dmon -s pucvmet -d 1'
```

Selector letters are power, utilisation, clocks, violations, memory, encoder,
temperature. Add `-o T` for wall-clock timestamps.

Both nodes interleaved in one window, `Ctrl-C` stops both:

```bash
( $DGX spark1 'nvidia-smi dmon -s pucm -d 1' | sed 's/^/[spark1] /' &
  $DGX spark2 'nvidia-smi dmon -s pucm -d 1' | sed 's/^/[spark2] /' &
  wait )
```

Full `nvidia-smi`, refreshing natively without a TTY:

```bash
$DGX spark1 'nvidia-smi -l 1'
```

Thermals and throttling. `v` is the violation selector, which is where throttle
events appear. `-s pt` gives power and temperature plus PCIe rates, not
violations. `mtemp` reads `-` on GB10, which has no separate memory sensor.

```bash
$DGX spark1 'nvidia-smi dmon -s pvt -d 1'
```

## Memory

GB10 has no discrete VRAM. CPU and GPU share one 121 GiB pool, so `nvidia-smi`
reports `-` for `fb` and `bar1` and `nvtop` shows `MEM: N/A`. GPU-side memory
readings are not useful. Watch system memory instead.

```bash
$DGX spark1 'while :; do free -h | awk "/Mem:/{printf \"%s  used %-6s avail %-6s\n\", strftime(\"%T\"), \$3, \$7}"; sleep 1; done'
```

Both nodes:

```bash
( $DGX spark1 'while :; do free -g | awk "/Mem:/{print \$3\"/\"\$2\" GiB\"}"; sleep 2; done' | sed 's/^/[spark1] /' &
  $DGX spark2 'while :; do free -g | awk "/Mem:/{print \$3\"/\"\$2\" GiB\"}"; sleep 2; done' | sed 's/^/[spark2] /' &
  wait )
```

## Interconnect

PHY counters report actual bytes on the wire. Both devices share one cable, so
either one gives total link utilisation.

```bash
$DGX spark1 'p=0; q=0; while :; do
  c=$(ethtool -S enp1s0f0np0 | grep -w tx_bytes_phy | tr -dc "0-9")
  r=$(ethtool -S enp1s0f0np0 | grep -w rx_bytes_phy | tr -dc "0-9")
  [ "$p" != 0 ] && printf "%s  tx %6d Mb/s   rx %6d Mb/s\n" "$(date +%T)" $(( (c-p)*8/1000000 )) $(( (r-q)*8/1000000 ))
  p=$c; q=$r; sleep 1
done'
```

One path saturates near 112000 Mb/s, both together near 196000.

Per-interface packet rates from a stock tool:

```bash
$DGX spark1 'sar -n DEV 2 | grep -E "IFACE|enp1s0f0np0|enP2p1s0f0np0"'
```

## vLLM and model status

### Live cluster view

```bash
bin/vllm-watch              # both nodes, 2s refresh
bin/vllm-watch spark1       # one node
bin/vllm-watch spark1 5     # one node, 5s refresh
```

Shows load progress while a node is starting and switches to throughput, queue
depth and KV cache usage once it is serving. Detects whether stdout is a
terminal: it repaints in place on a TTY and appends plain lines in a pipe, so
`bin/vllm-watch >> watch.log` works during a long run.

### Raw service log

The most detailed view, and the only one that shows startup errors:

```bash
$DGX spark1 'sudo journalctl -u vllm -f'
$DGX spark1 'sudo journalctl -u vllm -n 200 --no-pager'
```

Both nodes interleaved:

```bash
( $DGX spark1 'sudo journalctl -u vllm -f -o cat' | sed 's/^/[spark1] /' &
  $DGX spark2 'sudo journalctl -u vllm -f -o cat' | sed 's/^/[spark2] /' &
  wait )
```

### Startup stages

A cold start passes through four stages, roughly seven minutes in total on the
first run and less afterwards now that the compile cache persists:

| Stage | Log signature |
|---|---|
| Weight load | `Loading safetensors checkpoint shards: N%` |
| Dynamo transform | `Dynamo bytecode transform time` |
| Inductor compile | `Using cache directory ... torch_compile_cache` |
| CUDA graph capture | `Capturing CUDA graphs` |
| Ready | `/health` returns 200 |

Watch just the progress line:

```bash
$DGX spark1 'sudo journalctl -u vllm -f -o cat | grep --line-buffered -E "Loading safetensors|Capturing CUDA|Dynamo|startup complete"'
```

### Metrics

vLLM exposes Prometheus metrics once it is serving. Useful gauges:

```bash
$DGX spark1 'curl -s http://127.0.0.1:8000/metrics | grep -E "^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|generation_tokens_total|prompt_tokens_total)"'
```

| Metric | Meaning |
|---|---|
| `num_requests_running` | Currently decoding |
| `num_requests_waiting` | Queued, a sign of saturation |
| `kv_cache_usage_perc` | KV cache occupancy; near 1.0 means requests will start being preempted |
| `generation_tokens_total` | Counter; difference over time gives tokens/s |
| `prompt_tokens_total` | Counter; prefill volume |

List everything available:

```bash
$DGX spark1 'curl -s http://127.0.0.1:8000/metrics | grep -oE "^vllm:[a-z_]+" | sort -u'
```

### Readiness and identity

```bash
$DGX spark1 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/health'
$DGX spark1 'curl -s http://127.0.0.1:8000/v1/models'
```

`/v1/models` reports the served name and `max_model_len`, which is the quickest
way to confirm a config change actually took effect.

### Per-request timing

vLLM logs a throughput line per request at INFO. To watch requests as they
arrive:

```bash
$DGX spark1 'sudo journalctl -u vllm -f -o cat | grep --line-buffered -E "Avg prompt throughput|Avg generation throughput|Added request"'
```

### AnythingLLM

```bash
$DGX spark1 'sudo journalctl -u anythingllm -f'
$DGX spark1 'curl -s http://127.0.0.1:3001/api/ping'
```

## Fabric health

`rocep1s0f0` must read `PORT_ACTIVE`. `rocep1s0f1` and `roceP2p1s0f1` are
permanently `PORT_DOWN` because those cages are empty, which is expected.

```bash
$DGX spark1 'ibv_devinfo -d rocep1s0f0 | grep -E "state|link_layer"'
$DGX spark1 'ibv_devinfo | grep -E "hca_id|state:"'
```

Do not judge this fabric with `ping`. ICMP goes through the kernel stack and
reads about 1.25 ms; RDMA, which is what NCCL uses, is 1.66 µs.

Latency:

```bash
$DGX spark2 'ib_send_lat -d rocep1s0f0 -x 3 -F -n 5000'
$DGX spark1 'ib_send_lat -d rocep1s0f0 -x 3 -F -n 5000 192.168.100.2'
```

Bandwidth, expect about 112 Gb/s on one path:

```bash
$DGX spark2 'ib_write_bw -d rocep1s0f0 -x 3 -F --report_gbits -q 2 -s 1048576'
$DGX spark1 'ib_write_bw -d rocep1s0f0 -x 3 -F --report_gbits -q 2 -s 1048576 192.168.100.2'
```

`-x 3` is the RoCEv2-over-IPv4 GID index; confirm with
`show_gids | grep rocep1s0f0`.

## Combined and non-interactive

One line per tick, covering time, CPU, memory, network, disk and IO. This and
`glances --stdout` are the two worth piping to a log during a long run.

```bash
$DGX spark1 'dstat -tcmndr 2'
$DGX spark1 'glances --stdout now,cpu.total,mem.used,mem.percent'
$DGX spark1 'vmstat 2'
```

Disk. Watch `%util` and `w_await` when loading a large model from NVMe.

```bash
$DGX spark1 'iostat -xm 2 | grep -E "^Device|^nvme"'
```

Containers. Models will run in containers, and `docker stats` shows which one is
consuming the unified pool.

```bash
$DGX spark1 'docker stats'
$DGX spark1 'docker stats --no-stream'
$DGX spark1 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
```

## One-shot health check

```bash
for h in spark1 spark2; do
  echo "==== $h ===="
  $DGX $h '
    uptime
    nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader
    free -h  | awk "/Mem:/{print \"mem  \" \$3 \" / \" \$2}"
    df -h /  | awk "NR==2{print \"disk \" \$3 \" / \" \$2 \" (\" \$5 \")\"}"
    ip -brief addr show enp1s0f0np0 enP2p1s0f0np0 | awk "{print \$1, \$2, \$3}"
    ibv_devinfo -d rocep1s0f0 | awk "/state:/{print \"rdma \" \$2}"
    docker info --format "docker {{.ServerVersion}}, runtimes: {{range \$k,\$v := .Runtimes}}{{\$k}} {{end}}"
  '
done
```

## Known traps

`pkill -f` matches the command line you just typed and kills your own shell.
`pkill -f ib_write_bw` and `pkill -f 'L 11001:...'` both did this during setup.
Use `pkill -x <exact-name>`, or `kill` a PID from `pgrep`.

GPU memory readings are meaningless on GB10; use `free -h`.

`ping` latency is roughly 750× the real fabric latency; use `ib_send_lat`.

A stale apt index looks like a missing package. See `RUNBOOK.md` section 8
before concluding a package does not exist.

**Empty vLLM latency panels usually mean no traffic, not a broken dashboard.**
`histogram_quantile` over a rate window containing zero requests returns `NaN`,
which Grafana renders as "No data". The cluster serves a handful of requests a
day, so a 5-minute window is empty almost all the time. The dashboard has a
**Rate window** control at the top for this; widen it to 1h or 24h. The panels
also say "No requests in this window" rather than a bare "No data".

**Percentiles from a handful of samples are not trustworthy.** With six
requests in the window, p95 and p99 land in whichever coarse histogram bucket
holds the tail, and Grafana interpolates inside it — a p99 of 1,881 s appeared
from requests that all completed in under 30 s. p50 is meaningful at low sample
counts; the upper percentiles are not until the request rate is much higher.
