# Rebuild runbook

Every system-level command needed to take a DGX Spark from stock DGX OS to the
cluster's current state, in replay order. Read-only checks are included where
they gate a decision or confirm a step worked.

Keep this current. If a change isn't recorded here it is lost on the next
rebuild.

## Conventions

`[workstation]` runs on the local machine from the repo root. `[each node]` runs
on both Sparks. `[spark1]` and `[spark2]` run on one only.

| Alias | Hostname | Management IP | Management NIC |
|---|---|---|---|
| spark1 | `spark-a01a.tommyslab` | 10.255.129.236 | `enP7s7` |
| spark2 | `spark-9d80.tommyslab` | 10.255.131.79 | `enP7s7` |

Per node: NVIDIA GB10, 121 GiB unified memory, 3.7 TB NVMe, kernel
6.17.0-1014-nvidia aarch64, driver 580.142, Docker 29.2.1, ConnectX-7.

---

## 1. SSH keypair `[workstation]`

Keys live in this repository, not in `~/.ssh`. No passphrase, so automation can
use them non-interactively.

```bash
mkdir -p .ssh && chmod 700 .ssh
ssh-keygen -t ed25519 -f .ssh/dgx_spark -N "" -C "sudobasher-dgx-cluster"
chmod 600 .ssh/dgx_spark
chmod 644 .ssh/dgx_spark.pub
```

Current public key, to reuse when rebuilding only the nodes:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfVnHp0+bkAxjOue2i6Iixvr4POnEA92gL4s22vpBL+ sudobasher-dgx-cluster
```

Fingerprint `SHA256:mKg0EMDI02Ph6FC8Yl23Gk/cXmIhb2pMnQOCBADiiUc`.

`.gitignore` keeps the private key out of version control:

```gitignore
.ssh/*
!.ssh/*.pub
!.ssh/config
```

Confirm before the first commit. The private key must not appear:

```bash
git status --short --untracked-files=all
```

---

## 2. Create the `claude` user `[each node]`

Run as an existing sudo-capable account.

```bash
sudo useradd --create-home --shell /bin/bash --comment "Claude Code agent" claude

sudo install -d -m 700 -o claude -g claude /home/claude/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfVnHp0+bkAxjOue2i6Iixvr4POnEA92gL4s22vpBL+ sudobasher-dgx-cluster' \
  | sudo tee /home/claude/.ssh/authorized_keys > /dev/null
sudo chown claude:claude /home/claude/.ssh/authorized_keys
sudo chmod 600 /home/claude/.ssh/authorized_keys

sudo usermod -aG docker claude

# Interactive accounts that should use docker without sudo. Managed by the
# playbook via docker_users in ansible/group_vars/all.yml, listed here because a
# fresh node needs it before the playbook can be useful by hand.
sudo usermod -aG docker user
```

`useradd` leaves the password locked, which is intended: the key is the only way
in. `install -d` creates the directory already at mode 700 rather than creating
it 0755 and tightening afterwards. This matters because sshd's `StrictModes`
rejects the key if `~/.ssh` or the home directory is group- or world-writable,
and it fails without explanation on the client side.

Passwordless sudo. The account has no password, so ordinary `sudo` would prompt
and hang under automation. Note that docker group membership is already
root-equivalent in practice, since a container can bind-mount the host
filesystem, so this widens access less than it first appears.

```bash
echo 'claude ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/claude
sudo chmod 440 /etc/sudoers.d/claude
sudo visudo -c
```

Validate with `visudo -c` before logging out. If sshd has an allowlist, add
`claude` to it and reload:

```bash
sudo grep -E '^(AllowUsers|AllowGroups|PubkeyAuthentication)' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null
sudo -u claude ls -la /home/claude/.ssh
```

---

## 3. SSH client config `[workstation]`

`.ssh/config`, committed. `IdentitiesOnly` and `IdentityAgent none` ensure ssh
never falls back to a key in `~/.ssh` or the agent.

```sshconfig
Host spark1 spark-a01a spark-a01a.tommyslab
    HostName spark-a01a.tommyslab
    User claude

Host spark2 spark-9d80 spark-9d80.tommyslab
    HostName spark-9d80.tommyslab
    User claude

Host spark1 spark2 spark-a01a spark-9d80 spark-a01a.tommyslab spark-9d80.tommyslab
    IdentityFile /home/user/storage/development/github/sudobasher/dgx-cluster/.ssh/dgx_spark
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile /home/user/storage/development/github/sudobasher/dgx-cluster/.ssh/known_hosts
    ServerAliveInterval 30
    ServerAliveCountMax 4
```

The nodes moved from the `.local` (mDNS) network to the `tommyslab` domain on
2026-08-27; management addresses changed with it. The extra `.tommyslab` host
patterns exist because the `Host` block must match whatever name is typed, and
a bare `spark-a01a` and a fully qualified `spark-a01a.tommyslab` are different
patterns to ssh.

The 192.168.100.x/101.x interconnect is unaffected by any of this. It is a
private direct cable with static addresses, independent of the site network.

First connection pins host keys to the repo-local `known_hosts`. Names that
changed are pinned afresh, so expect new entries rather than a mismatch
warning:

```bash
for h in spark1 spark2; do
  ssh -F .ssh/config -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new "$h" \
      'echo "OK: $(whoami)@$(hostname) | $(uname -srm)"'
done
```

---

## 4. Baseline inventory

Reference snapshot. Re-run after a rebuild to confirm parity.

```bash
for h in spark1 spark2; do
  echo "==== $h ===="
  ssh -F .ssh/config "$h" '
    id
    free -h | head -2
    df -h / | grep -v tmpfs
    nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader
    docker info --format "{{.ServerVersion}}"
    sudo -n -l | tail -3
    ip -brief addr show | grep -v DOWN
    ls /sys/class/infiniband/
  '
done
```

Two deviations from a working state are expected on a fresh install and are
fixed in sections 5 and 6: Docker has no `nvidia` runtime registered, and the
ConnectX ports carry no IP addresses.

`nvidia-smi` reports `memory.total` as `N/A`. That is correct for GB10, where
CPU and GPU share one 121 GiB pool.

---

## 5. Register the NVIDIA container runtime `[each node]`

DGX OS ships `nvidia-container-toolkit` but does not wire it into Docker. There
is no `/etc/docker/daemon.json` out of the box, so `docker run --gpus` fails
until this runs.

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

This writes:

```json
{
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    }
}
```

Verify. `Runtimes` must list `nvidia`, and the GPU must appear inside a
container:

```bash
docker info | grep -iA1 Runtimes
docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L
```

Expect `GPU 0: NVIDIA GB10 (UUID: GPU-...)`.

---

## 6. ConnectX-7 interconnect

### Topology

One cable joins the nodes. Linux presents two devices that reach it, on separate
PCIe domains:

| Path | Device | PCI | RoCE device | Subnet |
|---|---|---|---|---|
| A | `enp1s0f0np0` | 0000:01:00.0 | `rocep1s0f0` | 192.168.100.0/24 |
| B | `enP2p1s0f0np0` | 0002:01:00.0 | `roceP2p1s0f0` | 192.168.101.0/24 |

The `f1` devices show `carrier=0`; the second QSFP cage is empty. These are not
two independent links. Both paths leave on the same wire, and the separate PCIe
domains only double the host-side bandwidth to it.

Do not try to map the cabling with LLDP or transceiver EEPROM. Both give wrong
answers here; see `FINDINGS.md`, "Measurement notes".

### Configuration `[each node]`

`/etc/netplan/50-cluster-interconnect.yaml`, with `.1` on spark1 and `.2` on
spark2. The renderer must match the installer config. Management traffic uses a
separate NIC managed by NetworkManager profiles and is deliberately absent here,
so applying this cannot cut an SSH session.

```yaml
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    enp1s0f0np0:
      dhcp4: false
      dhcp6: false
      addresses: [192.168.100.1/24]   # spark2: 192.168.100.2/24
      mtu: 9000
    enP2p1s0f0np0:
      dhcp4: false
      dhcp6: false
      addresses: [192.168.101.1/24]   # spark2: 192.168.101.2/24
      mtu: 9000
```

```bash
sudo chmod 600 /etc/netplan/50-cluster-interconnect.yaml
sudo netplan apply
```

Netplan warns if the file is group- or world-readable. Addresses added with a
bare `ip addr add` are stripped by NetworkManager within minutes, so always
persist them here or later tests will fail confusingly.

Add names to `/etc/hosts` on both nodes:

```
192.168.100.1   spark1-ic
192.168.100.2   spark2-ic
```

### Verification

```bash
ip -brief addr show enp1s0f0np0
ping -c 3 -M do -s 8972 192.168.100.2          # jumbo frames, must not fragment
ibv_devinfo | grep -E 'hca_id|state:'           # rocep1s0f0 must be PORT_ACTIVE
show_gids | grep rocep1s0f0                     # GID index 3 = RoCEv2 over IPv4
```

Bandwidth, server on spark2 and client on spark1:

```bash
# spark2
ib_write_bw -d rocep1s0f0 -x 3 -F --report_gbits -q 2 -s 1048576
# spark1
ib_write_bw -d rocep1s0f0 -x 3 -F --report_gbits -q 2 -s 1048576 192.168.100.2
```

Both rails at once, which is the actual 200G test. The server side must stay in
a live SSH session — backgrounding it with `nohup`/`setsid` over `ssh` leaves it
dead and the client reports `Couldn't connect`:

```bash
# spark2, one shell
ib_write_bw -d rocep1s0f0   -x 3 -F --report_gbits -q 2 -s 1048576 -D 15 -p 18515 &
ib_write_bw -d roceP2p1s0f0 -x 3 -F --report_gbits -q 2 -s 1048576 -D 15 -p 18516 &
wait
# spark1, one shell
ib_write_bw -d rocep1s0f0   -x 3 -F --report_gbits -q 2 -s 1048576 -D 15 -p 18515 192.168.100.2 &
ib_write_bw -d roceP2p1s0f0 -x 3 -F --report_gbits -q 2 -s 1048576 -D 15 -p 18516 192.168.101.2 &
wait
```

Expect about 112 Gb/s on one path and 196 Gb/s driving both. Latency via
`ib_send_lat` should be about 1.7 µs. Do not use `ping` to judge the fabric; it
reads 1.25 ms because ICMP goes through the kernel stack.

Measured 2026-08-31: rail A alone 111.86 Gb/s, rail B alone 111.47 Gb/s, both
together 98.04 + 98.04 = 196.08 Gb/s. `ib_send_lat` 1.38 µs typical, 1.48 µs at
the 99th percentile. Both rails carry 8972-byte unfragmented pings. No
`rx_crc_errors_phy`, `rx_symbol_error_phy`, or discards on either node.

Check the PHY error counters after any bandwidth run:

```bash
sudo ethtool -S enp1s0f0np0 | grep -E 'crc_errors_phy|symbol_error_phy|discards_phy|link_down_events_phy'
```

A nonzero `link_down_events_phy` matching the number of `netplan apply` runs
since boot is expected. CRC or symbol errors are not, and mean the cable or a
transceiver needs reseating.

### Loop safety

Do not bond or bridge the two devices. They share one wire, so a bond gains
nothing, and bridging would create a loop. Confirm nothing bridges them:

```bash
bridge link show | grep -E 'enp1s0f0np0|enP2p1s0f0np0'   # expect no output
```

---

## 7. Intra-cluster SSH `[each node]`

Distributed launchers need passwordless SSH between nodes over the interconnect.
Use a keypair separate from the workstation key.

```bash
# spark1
ssh-keygen -t ed25519 -f ~/.ssh/cluster -N "" -C "spark-intra-cluster"
```

Copy the pair to spark2 without staging it anywhere else, piping host to host
from the workstation:

```bash
ssh -F .ssh/config spark1 'cat ~/.ssh/cluster'     | ssh -F .ssh/config spark2 'cat > ~/.ssh/cluster && chmod 600 ~/.ssh/cluster'
ssh -F .ssh/config spark1 'cat ~/.ssh/cluster.pub' | ssh -F .ssh/config spark2 'cat > ~/.ssh/cluster.pub && chmod 644 ~/.ssh/cluster.pub'
```

Authorise on both nodes and give each a client config:

```bash
grep -qF "$(cat ~/.ssh/cluster.pub)" ~/.ssh/authorized_keys \
  || cat ~/.ssh/cluster.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

cat > ~/.ssh/config <<'EOF'
Host spark1-ic spark2-ic
    User claude
    IdentityFile ~/.ssh/cluster
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
chmod 600 ~/.ssh/config
```

Verify both directions:

```bash
ssh -F .ssh/config spark1 'ssh spark2-ic hostname'   # spark-9d80
ssh -F .ssh/config spark2 'ssh spark1-ic hostname'   # spark-a01a
```

---

## 8. Monitoring tooling `[each node]`

DGX OS ships only `htop`, `top`, `sar` and `iostat`. Everything else is
installed by the playbook from `node_packages` in
`ansible/group_vars/all.yml` (nvtop, btop, glances, iftop, bmon, nload, dstat,
sysstat, traceroute, mtr-tiny, iperf3, rsync). By hand:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  nvtop btop glances iftop bmon dstat sysstat nload traceroute mtr-tiny iperf3 rsync
```

A stale apt index can look like a missing package. On spark2 this failed with
`E: Unable to locate package nvtop` while spark1 succeeded, from byte-identical
sources. `universe` was enabled and `apt-get update` reported only `Hit:` lines,
but the universe `Packages` file had never been fetched. Force it:

```bash
sudo rm -f /var/lib/apt/lists/ports.ubuntu.com_*
sudo apt-get update
apt-cache policy nvtop        # Candidate: 3.0.2-1
```

One missing package aborts the whole `apt-get install`, so nothing else in the
list gets installed either. Check rather than assume:

```bash
for t in nvtop btop glances iftop bmon dstat nload sar iostat htop; do
  printf "%-10s %s\n" "$t" "$(command -v $t || echo MISSING)"
done
```

`nvtop` detects the GB10 and reports utilisation, temperature, power and
per-process GPU usage, but shows `MEM: N/A` because there is no discrete VRAM.
Use `free -h` for memory. See `MONITORING.md` for dashboards and streaming
commands.

---

## 9. Verification benchmarks

Not required to reach a working state, but these establish the baseline the
cluster should reproduce after a rebuild. Results and interpretation are in
`FINDINGS.md`.

### 9a. GPU memory bandwidth

Needs a CUDA container; the hosts have no `nvcc` and no torch.

```bash
docker pull nvidia/cuda:13.0.0-devel-ubuntu24.04     # 10.4 GB

nvidia-smi --query-gpu=compute_cap --format=csv,noheader     # 12.1 -> sm_121

cat bench/gpubw.cu | ssh -F .ssh/config <node> \
  'docker run --rm -i --gpus all nvidia/cuda:13.0.0-devel-ubuntu24.04 bash -c \
   "cat > /g.cu && nvcc -O3 -arch=sm_121 -o /g /g.cu && /g"'
```

Piping the source over stdin avoids a host bind mount. Detect the architecture
rather than guessing it.

Expect read bandwidth near 261 GB/s, which is 96% of the 273 GB/s theoretical.

### 9b. NCCL cross-node all-reduce

Build the image on both nodes:

```bash
printf '%s\n' \
  'FROM nvidia/cuda:13.0.0-devel-ubuntu24.04' \
  'RUN apt-get update && apt-get install -y --no-install-recommends libnccl-dev=2.27.7-1+cuda13.0 libibverbs1 librdmacm1 ibverbs-providers ibverbs-utils rdma-core && rm -rf /var/lib/apt/lists/*' \
  | ssh -F .ssh/config <node> 'docker build -q -t nccl-bench -'

tar -C bench -c Dockerfile.nccl allreduce_bw.cu \
  | ssh -F .ssh/config <node> 'docker build -q -t nccl-bench:bin -f Dockerfile.nccl -'
```

`libnccl2` is already present in the CUDA base image at 2.27.7. Installing
`libnccl-dev` unpinned pulls 2.31.2 and fails on the version conflict, so pin it.

`libibverbs1` and `ibverbs-providers` are mandatory. Without them NCCL falls back
to `NET/Socket` and reports 1.5 GB/s while appearing healthy.

Run with `bench/run_allreduce.sh`. Rank 0 on spark1 emits its `ncclUniqueId` as
hex; the launcher passes it to rank 1 on spark2. No MPI needed.

Container flags, all required:

```
--gpus all --network host --ipc host --shm-size=1g --ulimit memlock=-1
--cap-add IPC_LOCK --device=/dev/infiniband/rdma_cm
--device=/dev/infiniband/uverbs0 ... uverbs3
```

`--device` does not recurse into a directory, so list each `uverbs*` node.

Environment:

```bash
NCCL_IB_HCA=rocep1s0f0,roceP2p1s0f0    # both paths; doubles bandwidth
NCCL_IB_GID_INDEX=3
NCCL_SOCKET_IFNAME=enp1s0f0np0
NCCL_IB_DISABLE=0
```

Expect 3.04 GB/s on both paths and 25 µs for a 16 KB all-reduce. Confirm
`NCCL_DEBUG=INFO` reports `Using network IB`.

GPUDirect RDMA does not work on this platform: NCCL reports `GDR 0`,
`nvidia-peermem.ko` fails to insert, and 3 GB/s is a hard ceiling. Re-test
`modprobe nvidia_peermem` after any driver update. If it ever loads, re-run this
section, because a working GDR path would change the serving topology decision.

---

## 10. Model serving stack

Managed by Ansible, not by hand. See `ansible/README.md` for the full
operational guide; this section covers only what a rebuild needs.

Each node runs one vLLM container under a systemd unit, serving one model, with
no cross-node coupling. Models that fit in 121 GiB are never split, because
NCCL collectives across the interconnect manage 3.0 GB/s and tensor parallel
would make prefill roughly 200× slower than keeping the model local (section 9b
and `FINDINGS.md`).

Current assignment, both nodes identical for now:

| Node | Model | Served as | Port |
|---|---|---|---|
| spark1 | `Qwen/Qwen3.8-27B-FP8` | `qwen3.8-27b` | 8000 |
| spark2 | `Qwen/Qwen3.8-27B-FP8` | `qwen3.8-27b` | 8000 |

From the `ansible/` directory:

```bash
ansible-playbook site.yml                    # both nodes
ansible-playbook site.yml --limit spark2     # one node
```

Per-node configuration is in `ansible/host_vars/`. Changing `ms_model_repo`
there and re-running with `--limit` repoints one node without touching the
other; setting `ms_enabled: false` tears its service down and frees the node.

Weights are cached in `/opt/dgx-models` on each node, outside the container, so
they survive image changes and redeployment. First run takes 30–60 minutes per
node for a 10 GB image and 28 GB of weights.

Two prerequisites the playbook asserts before doing anything: Docker must
expose the `nvidia` runtime (section 5) and at least 100 GB must be free.

Notes that cost a run each:

- `stdout_callback = yaml` fails on ansible-core 2.16. The
  `community.general.yaml` callback was removed in v12; use
  `result_format = yaml` with the default callback instead.
- Do not set `ansible_host` in the inventory. The SSH config's `Host` blocks
  match `spark1` and `spark-a01a`, not `spark-a01a.tommyslab`, so pointing Ansible
  at the FQDN bypasses the `IdentityFile` and fails on publickey. Let the
  inventory hostnames be the SSH aliases.

`ms_gpu_memory_utilization` defaults to 0.80 rather than the usual 0.90. GB10
shares one 121 GiB pool between CPU and GPU, so whatever vLLM reserves is taken
from the host, not from spare VRAM.

---

## 11. AWS infrastructure `[workstation]`

OpenTofu, pinned to 1.12.6 by `required_version` so tenv selects it
automatically. Profile `isc-eng-hpcresearch-dev`, account 376129860391,
region us-west-2.

State lives in S3 with native conditional-write locking, so there is no
DynamoDB lock table. The bucket cannot exist before it is created, so the
bootstrap runs once with local state:

```bash
cd terraform/bootstrap && tofu init && tofu apply
cd ../            && tofu init && tofu apply
```

Everything is tagged `createdBy = tommy.aldo.sonin` through `default_tags`.

`terraform.tfvars` holds NetBird setup keys and is gitignored.

Three things worth knowing.

An **S3 Gateway VPC Endpoint is required**, not optional. It is free and keeps
every Thanos block flush and chunk fetch inside the VPC.

`source_dest_check` must be false on netbird-cp, or EC2 drops forwarded
packets.

**The observability subnet routes via the internet gateway, not the NAT
instance**, despite still being named `private`. The nodes carry Elastic IPs so
WireGuard hole punching can work; behind MASQUERADE it never could, because
Linux does endpoint-dependent filtering and silently drops inbound hole-punch
packets. They are not exposed: the security group admits UDP 51820 and nothing
else, so SSH and Grafana remain overlay-only. This is what turned the
Spark-to-AWS path from relayed at 82 ms into direct at 32 ms.

---

## 12. NetBird control plane `[netbird-cp]`

```bash
cd ansible && ansible-playbook aws.yml
```

The upstream installer prompts on a TTY but reads environment variables when
there is none, so Ansible drives it without a pty. `NETBIRD_DOMAIN` and
`NETBIRD_LETSENCRYPT_EMAIL` are the only required ones.

**Docker sets the FORWARD policy to DROP**, which silently breaks the NAT
routing this host provides for the private subnet. Packets arrive and are
dropped before reaching the masquerade rule, which then shows a zero packet
count and appears correct. The accept rules must go in `DOCKER-USER`; Docker
evaluates that chain first and never rewrites it.

Create the first admin account by hand at `https://vpn.isc-spectro-sbx.click/setup`.
That page exists only until the first user is created.

Groups, setup keys, policies, routes and the lockdown are declarative:

```bash
cd ansible && ansible-playbook netbird-access.yml
```

The desired state lives in `roles/netbird_config/defaults/main.yml`. It runs
against the API from localhost, needs no managed host, and converges to
`changed=0` on a second run.

Two things that bite. Policy `ports` must be **strings**; integers are rejected
with a null body and HTTP 200, so the failure looks like success. And the
policy set must include the machine-to-machine paths (`sparks-to-aws`,
`aws-internal`) — without them, disabling the All-to-All default silently takes
telemetry to zero, because nothing logs into those paths and nothing errors.

---

## 13. Observability stack `[obs-write, obs-read]`

```bash
cd ansible && ansible-playbook observability.yml
```

Split by role: obs-write runs Thanos receive, the compactor and Loki; obs-read
runs Thanos query and store, Grafana and memcached. The split exists to keep
bursty compaction away from user queries.

Both self-enrol into the VPN first, then the stack comes up. Data goes to
`s3://dgx-cluster-telemetry-376129860391` via the instance profile, so no keys
appear in any config.

Three traps, each of which cost a deploy cycle:

- **Container uids differ per image**: thanos 1001, loki 10001, grafana 472.
  Read them with `docker inspect -f '{{.Config.User}}'` rather than assuming.
  A mismatch is a permission-denied crash loop.
- **thanos-receive binds remote-write port + 100** (19391) for remote-write
  gRPC, which no flag reveals. The compactor uses 10903 to avoid it.
- Thanos uses kingpin, so **boolean flags reject `=value`** and fail with
  `error: unexpected false`.

Datasources and dashboards are provisioned from the role, not clicked in:

| Dashboard | uid | Panels | Covers |
|---|---|---|---|
| vLLM and Qwen performance | `vllm-qwen` | 20 | tokens/s, TTFT, ITL, KV cache, preemption, prefix cache |
| Fleet health | `fleet` | 11 | CPU, unified memory, disk, GPU util, temperature, power, 200GbE |
| Observability stack health | `obs-self` | 10 | ingest rate, remote-write queue, compaction, query p95 |

Two more traps here:

- **Grafana cannot change the uid of an already-provisioned datasource.** It
  fails with "data source not found" and refuses to start. The template carries
  a `deleteDatasources` stanza that removes them by name first, which makes the
  uids (`thanos`, `loki`) stable across rebuilds. The provisioned dashboards
  reference those uids, so they must not drift.
- **The datasource URL must be `127.0.0.1`, not the Compose service name.**
  These containers run with `network_mode: host`, so Docker's embedded DNS does
  not resolve `thanos-query`. Using the service name breaks every metric panel
  and surfaces first as a Drilldown plugin error rather than an obvious
  connection failure.

`allowUiUpdates` is on, so browser edits stick until the next playbook run
overwrites them. Export anything worth keeping into
`roles/observability/files/dashboards/`.

The Grafana admin password comes from `.secrets/grafana.yml`, loaded by
`observability.yml` via `vars_files`. Grafana applies
`GF_SECURITY_ADMIN_PASSWORD` only when initialising a fresh database — a
password later changed in the UI persists and the environment variable is
ignored — so that file must be kept in step with reality or a rebuild from an
empty volume will come up with the `admin` default.

---

## 14. Telemetry agents `[sparks, observability]`

```bash
cd ansible && ansible-playbook telemetry.yml
```

Installs node_exporter with the ethtool collector enabled, dcgm-exporter on GPU
hosts, and an OpenTelemetry Collector that scrapes locally and ships metrics to
Thanos and logs to Loki over the VPN.

Scrape intervals are 1s for everything except vLLM at 5s: its `/metrics`
handler runs inside the serving process, and 60 scrapes a minute against a node
already at 105 of 121 GiB risks perturbing what is being measured.

The collector keeps a persistent on-disk queue so a network outage does not
lose telemetry.

Two things that are easy to get wrong:

- **`ansible_managed` is injected by the `template` module only.** Referencing
  it inside `copy: content:` fails with "undefined variable", and setting it in
  `ansible.cfg` does not help.
- **The journald receiver puts the whole journal entry in the log body**, not
  in attributes. A transform is needed to set `service.name` from
  `body["_SYSTEMD_UNIT"]` and to reduce the body to `body["MESSAGE"]`.
  Without it every log is `unknown_service` and renders as a JSON blob.

Verify:

```bash
ssh -F .ssh/config obs-read \
  'curl -s "http://127.0.0.1:19192/api/v1/query?query=up" | jq -r ".data.result[].metric|\"\(.job)@\(.node)\""'
```

Expect node, otelcol, dcgm and vllm from both Sparks, plus the Thanos, Loki and
Grafana components from both observability nodes.

---
## 15. End-to-end verification `[workstation]`

Run after any rebuild. Each check fails loudly rather than degrading quietly,
which matters because most of the faults in this build were silent.

```bash
# 1. VPN. Expect every peer Connected or Idle, none Disconnected.
netbird status -d

# 2. Scrape health. Expect 18.
curl -s --get http://100.123.229.83:19192/api/v1/query \
  --data-urlencode 'query=sum(up)'

# 3. Per-target breakdown, when the count is short.
curl -s --get http://100.123.229.83:19192/api/v1/query \
  --data-urlencode 'query=up' \
  | jq -r '.data.result[] | "\(.metric.node)\t\(.metric.job)\t\(.value[1])"' | sort

# 4. Logs are arriving and are attributed to a unit, not unknown_service.
curl -s -G http://100.123.158.113:3100/loki/api/v1/label/service_name/values | jq -r '.data[]'

# 5. Both model servers answer.
for h in 100.123.96.149 100.123.5.235; do
  curl -s http://$h:8000/v1/models | jq -r '.data[].id'
done

# 6. Grafana is up and its dashboards are provisioned.
curl -s http://100.123.229.83:3000/api/health | jq -r '.database'
```

Expected results, as measured on 2026-09-03:

| Check | Expected |
|---|---|
| Peers connected | 2/3 from each Spark, obs-read Idle until queried |
| `sum(up)` | 18 |
| Loki `service_name` | `vllm.service`, `anythingllm.service`, `docker.service`, `otelcol-contrib.service`, `init.scope`, `unknown_service` |
| `/v1/models` | `qwen3.8-27b` from both nodes |
| Grafana health | `ok`, version 13.0.8 |

`unknown_service` in that list is expected, not a fault: kernel messages carry
no systemd unit, so the transform has nothing to set `service.name` from.

A `sum(up)` below 18 with everything else healthy is usually a single exporter,
not a network fault. Check the breakdown before touching the VPN.

---

## 16. vLLM access control `[sparks]`

```bash
cd ansible && ansible-playbook site.yml
```

Two independent controls, because neither is sufficient alone.

**Per-client API keys.** `ms_api_keys` in `.secrets/vllm-keys.yml`, one entry
per client, rendered into the unit. Revoke by deleting an entry and re-running.

> All keys must go on a **single** `--api-key` flag. The argument is
> `nargs='+'`, so repeating the flag keeps only the last value and every other
> client gets 401 with nothing logged at startup to explain it.

**Source-network allowlist.** `ms_allowed_cidrs`, applied by
`vllm-firewall.service` into DOCKER-USER. This exists because `--api-key` only
guards `/v1`, `/v2` and `/inference`: **`/invocations` offers the same inference
and is unauthenticated**, so keys alone are bypassable in one request. Being
network-level, the allowlist covers it.

The rules must go in DOCKER-USER and be inserted, not appended: that chain ends
in a `RETURN`, so an appended rule is never reached. Rules are tagged with an
iptables comment so a re-run removes its predecessors rather than stacking.
The unit is enabled because Docker rebuilds its chains on restart and discards
them.

Verify:

```bash
KEY=<a key from .secrets/vllm-keys.yml>
curl -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY" \
  http://100.123.96.149:8000/v1/models      # 200
curl -o /dev/null -w '%{http_code}\n' http://100.123.96.149:8000/v1/models   # 401
curl -o /dev/null -m 8 -w '%{http_code}\n' \
  http://spark-a01a.tommyslab:8000/v1/models  # 000, blocked from the lab LAN
```

---
