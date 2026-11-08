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

Current assignment. Both nodes serve the same model since 2026-11-08
(section 22); spark2 is due to be wiped, after which spark1 is the only
serving node:

| Node | Model | Served as | Port | vLLM |
|---|---|---|---|---|
| spark1 | `nvidia/Qwen3.6-35B-A3B-NVFP4` | `qwen3.6-35b-a3b` | 8000 | `v0.33.0`, pinned (Qwen3.8-27B on `:latest` until 2026-11-08) |
| spark2 | `nvidia/Qwen3.6-35B-A3B-NVFP4` | `qwen3.6-35b-a3b` | 8000 | `v0.33.0`, pinned (was `v0.28.0` until 2026-11-07); to be wiped |

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
| Loki `service_name` | `vllm.service`, `openwebui.service` (both Sparks since 2026-11-08; `anythingllm.service` before that), `docker.service`, `otelcol-contrib.service`, `init.scope`, `unknown_service` |
| `/v1/models` | `qwen3.6-35b-a3b` from both (spark1 since 2026-11-08, spark2 since 2026-11-06) |
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

## 17. Administrative accounts `[sparks, observability]`

```bash
cd ansible && ansible-playbook admin-users.yml
```

Key-only, NOPASSWD sudo accounts, distinct from the per-service accounts
(`claude`, `ubuntu`) that own the deployed workloads. Defined in
`admin-users.yml`, applied by the `admin_users` role: create the account,
install its public key(s), then write a dedicated `/etc/sudoers.d/<file>`
granting `ALL=(ALL) NOPASSWD:ALL`, validated with `visudo -cf` before it
replaces anything on disk.

NOPASSWD, not just `sudo`-group membership: these accounts have no password
set, so an interactive sudo prompt would be a lockout rather than a
safeguard.

The role is additive per play — a play only touches the users listed in its
own `admin_users` var, never removing an account outside that list. Two plays
in `admin-users.yml`:

| Account | Scope | sudoers file |
|---|---|---|
| `tommy.aldo.sonin` | both Sparks, both observability nodes | `/etc/sudoers.d/sudobasher` |
| `alex.scammon` | spark2 only | `/etc/sudoers.d/vanguard` |

netbird-cp is not in scope for either; add a third play if a login is needed
there too.

Verify:

```bash
ansible sparks:observability -b --become-user tommy.aldo.sonin -a 'whoami'
ansible spark2 -b --become-user alex.scammon -a 'whoami'
```

### VPN access for a new person

A dedicated, single-use NetBird setup key, not the shared `teammate-device`
key, so the grant is individually attributable and revocable:

```yaml
# roles/netbird_config/defaults/main.yml
- { name: alex.scammon, groups: [teammates], usage_limit: 1 }
```

`usage_limit: 1` selects `type: one-off` in the role — the key stops working
after first use, so handing it to one person doesn't hand it to whoever else
sees it.

**Trap:** the `uri` module's `body:` truncates when a YAML dict mixes a value
built from a Jinja conditional with a value built from a filter chain (here,
`type` from an `if/else` and `usage_limit` from `default()`) — the request
lands as a 53-byte fragment of the intended ~170 bytes and the API returns
`400 couldn't parse JSON request`, with no indication that the body itself was
the problem. The fix is to render the whole body as one string with `to_json`
rather than letting the module template a dict of independently-templated
values:

```yaml
body: >-
  {{ { 'name': item.name, 'type': (...), 'usage_limit': (...), ... } | to_json }}
```

The four pre-existing keys never hit this because none of their fields used a
filter or a conditional — literal `type: reusable` and `usage_limit: 0`
templated fine as plain dict values.

### Reissuing an expired one-off key

2026-10-14: `alex.scammon` needed a key for a new laptop. The key issued
2026-09-04 had expired unused on 2026-10-04 — `nbcfg_setup_key_ttl` is 30 days
and the clock starts at creation, not at first use.

The role creates a setup key only when no key of that name exists, and has no
update or delete path, so re-running the playbook does not refresh an expired
key. A reissue is therefore a new entry under a new name:

```yaml
# roles/netbird_config/defaults/main.yml
- { name: alex.scammon-laptop, groups: [teammates], usage_limit: 1 }
```

```bash
cd ansible && ansible-playbook netbird-access.yml 2>&1 | tee ../logs/netbird-access-20261014.log
```

The key value prints once, in the "Report any newly issued setup keys" task,
and is then only retrievable from `.secrets/netbird-keys.yml` where it is
recorded by hand. Verify by re-running: the create task skips and the report
task prints nothing (ok drops 14 -> 12, skipped rises 4 -> 6).

The dead `alex.scammon` key stays in NetBird and in the defaults, commented, so
the name stays taken and the next reader sees why there are two entries. Delete
both the NetBird key and the entry if the accumulation starts to matter — the
dashboard's Setup Keys page is the list that counts.

Every other setup key was also expired at this point (`valid: false` on all
six), which blocks new enrollments but not existing peers — an enrolled peer
holds its own credentials and never re-reads the setup key. Worth a role change
that reissues on expiry rather than six more manual renames.

---

## 18. Bringing netbird-cp into telemetry `[netbird-cp]`

```bash
cd ansible && ansible-playbook telemetry.yml --limit netbird-cp
```

netbird-cp was outside the telemetry fleet until now — it runs no client, so
it has no overlay address, unlike every other host this project ships logs or
metrics from. `group_vars/aws.yml` routes it to obs-write's **VPC-private IP**
(`10.200.10.116`) instead; both instances sit in the same VPC and the
observability security group already admits all in-VPC traffic
(`obs_from_vpc` in `terraform/security.tf`), so this needed no firewall change.

Logs only at first: `tel_enable_node_exporter: false` skipped installing
node_exporter altogether, rather than running it with nothing scraping it.
Later reversed - `tel_enable_node_exporter: true` plus a `node` scrape job -
once host CPU/memory/disk on netbird-cp was wanted on the Fleet health
dashboard too. Its panels carry no node filter, so nothing needed changing
there; the fix was entirely in `group_vars/aws.yml`.

One thing to expect and not read as broken: the CPU panel shows a spike
(spuriously as high as 80%) for the first ~30-60s after node_exporter starts
or restarts. `rate()` is measuring a partial, not-yet-full window at that
point; it settles as more samples accumulate. `top` on the host is the
ground truth if a reading looks wrong right after a redeploy.

Two things that broke on the first attempt:

**An empty `tel_scrape_jobs` is not "zero metrics."** The collector's pipeline
unconditionally references the `prometheus` receiver, and a receiver with no
`scrape_configs` fails its own validation — `no Prometheus scrape_configs or
target_allocator set` — which crash-loops the whole collector, logs included,
not just metrics. The fix: give netbird-cp the same self-scrape job every
other host already carries (`otelcol` → `127.0.0.1:8888`), the minimum that
keeps the receiver valid.

**thanos-receive's remote-write listener was bound to the overlay IP only**
(`--remote-write.address={{ obs_write_ip }}:19291`), so even with the VPC
route and security group in place, nothing was listening on the VPC-private
address netbird-cp actually connects to — `context deadline exceeded`,
repeating every scrape interval. The security group, not that bind, is the
real boundary: anything in the VPC already reaches every port on obs-write.
Widened to `0.0.0.0:19291` to match how `--grpc-address` and `--http-address`
were already bound on the same line above it.

Verify:

```bash
ansible netbird-cp -b -a 'systemctl is-active otelcol-contrib'
curl -s --get http://100.123.229.83:19192/api/v1/query \
  --data-urlencode 'query=up{node="netbird-cp"}'
```

### SSH auth logs, fleet-wide

Both Sparks now ship `ssh.service` alongside the units they already carried
(`group_vars/sparks.yml`). Combined with netbird-cp above, all three
non-observability hosts now surface sshd authentication events in Loki, with
two Logs panels on the **Fleet health** dashboard's new Security row:

| Panel | Query |
|---|---|
| SSH auth — Sparks | `{service_name="ssh.service"} \| node =~ "spark1\|spark2"` |
| SSH auth — NetBird control plane | `{service_name="ssh.service"} \| node =~ "netbird-cp"` |

The second one is host login to netbird-cp, not NetBird's own dashboard or
management-API authentication, which is a separate signal covered next.

### VPN auth, distinct from host login

NetBird's own containers (`netbird-server`, `netbird-dashboard`,
`netbird-traefik`) are managed by `docker compose`, generated by NetBird's own
installer script, and logged to per-container `json-file` on disk by default —
invisible to a journald-based pipeline no matter what unit list it carries.

Getting these into Loki as their own service, not merged into `docker.service`
with every other daemon message, took two changes, both in `roles/netbird_server`:

**A Compose override file, not a daemon default.** `/etc/docker/daemon.json`
setting `log-driver: journald` looked sufficient but was not: the vendor
compose file pins `driver: json-file` explicitly per service, and an explicit
per-service value always wins over the daemon default. Compose auto-merges a
`docker-compose.override.yml` placed alongside the vendor file, which is how
this changes without editing a file the installer script owns and could
regenerate. Containers must also be recreated, not just restarted — the log
driver is fixed at container-create time.

**The transform must check `CONTAINER_NAME` before `_SYSTEMD_UNIT`.** Even
with the journald driver, `_SYSTEMD_UNIT` on every entry is still
`docker.service` — the daemon, not the container, is journald's attribution
point. `CONTAINER_NAME` (present only on docker-journald-driver entries, with
a leading slash) is what actually identifies which container wrote it, so it
must be checked first, before the existing `_SYSTEMD_UNIT` fallback collapses
everything into `docker.service`. `netbird-cp`'s `docker` unit stays in
`tel_journal_units` for this reason — it is the daemon's attribution, not a
per-container one, that makes these entries visible to the receiver at all.

Verify:

```bash
ansible netbird-cp -b -m shell -a   'docker inspect --format "{{ "{{" }}.HostConfig.LogConfig.Type{{ "}}" }}" netbird-server'
curl -s --get http://100.123.158.113:3100/loki/api/v1/label/service_name/values   | jq -r '.data[]'
```

Expect `journald`, and `netbird-server` / `netbird-dashboard` / `netbird-traefik`
each as their own entry in the label list — the same way `vllm.service` and
`ssh.service` already are.

---

## 19. Grafana accounts `[obs-read]`

```bash
cd ansible && ansible-playbook observability.yml --limit obs-read
```

Declarative, via Grafana's own HTTP API — `obs_grafana_users` in
`.secrets/grafana.yml`, one entry per named account: `login`, `name`,
`password`, `is_admin`. Applied after the health-check wait, since it needs
the live API, not just the rendered config.

`is_admin: true` sets both switches Grafana treats separately: the
organisation role (`Admin`, via `PATCH /api/org/users/:id`) and the
server-wide flag (`isGrafanaAdmin`, via `PUT /api/admin/users/:id/permissions`).
A dashboard-only account would need neither.

The `uri` module doesn't compute a changed flag for a POST on its own, so
every task in this block reports `ok` even on first creation — that's normal,
not a sign nothing happened. Verify with the account's own credentials, not
the task output:

```bash
curl -s -u '<login>:<password>' http://100.123.229.83:3000/api/user
```

200 with that user's own object back is the only real confirmation.

---

## 20. spark2 on Qwen3.6-35B-A3B NVFP4 `[spark2]`

```bash
cd ansible && ansible-playbook site.yml --limit spark2 --diff 2>&1 | tee ../logs/site-spark2-20261106.log
```

Repointed 2026-11-06. spark2 stops being a replica of spark1 and becomes the
fast node: a mixture-of-experts model with ~3B parameters active per token,
quantised to 4-bit. spark1 keeps the dense Qwen3.8-27B for work that needs the
deeper model. (Superseded 2026-11-08: spark1 now runs this same setup, section
22, and spark2 is due to be wiped.)

| | spark1 | spark2 |
|---|---|---|
| Model | `Qwen/Qwen3.8-27B-FP8` | `nvidia/Qwen3.6-35B-A3B-NVFP4` |
| Served as | `qwen3.8-27b` | `qwen3.6-35b-a3b` |
| Decode, single stream | 8.4 tok/s | 77.1 tok/s |
| Time to first token | 0.14 s | 0.07 s |
| Weights on disk | 29 GB | 22 GB |
| Cold start | ~7 min | 3 min 28 s |

*Table 20.1. Both nodes measured 2026-11-06, same prompt, 512 output tokens
with `ignore_eos`, thinking off, one warm-up then three runs each. Runs varied
by less than 0.2 tok/s.*

Decode on GB10 is bound by memory bandwidth, so speed tracks the bytes read per
token. The 27B reads all ~28 GB of its weights for every token; the MoE reads
only the experts the router picks. That ratio, not any serving flag, is the
9.2x.

### What changed

Everything is in `ansible/host_vars/spark2.yml`; the role is untouched.

- `ms_model_repo` and `ms_served_name` point at the NVFP4 checkpoint.
- `ms_image` was pinned to `vllm/vllm-openai:v0.28.0` (moved to `v0.33.0` on
  2026-11-07, see below). `:latest` had moved to
  0.33.0, and 0.28.0 is both what the vLLM GB10 recipe measured on and the
  minimum at which FlashInfer selects its XQA decode kernel on SM12x for NVFP4.
  The tag resolved to the image already on disk (`61fc8a896b0a`), so nothing
  new was pulled.
- `ms_gpu_memory_utilization: 0.5`, the recipe's cap for Spark. vLLM holds
  20.4 GiB of weights plus a 1.4M-token KV cache (5.4 concurrent requests at
  full 262144 context); the host keeps ~71 GiB.
- `ms_extra_args` carries the recipe's serving flags: fp8 KV cache, FlashInfer
  attention, Marlin MoE, `--max-num-seqs 8`, chunked prefill, async
  scheduling, prefix caching (turned off 2026-11-08, see the known issue),
  fastsafetensors loading. Each was checked
  against `vllm serve --help=all` in the pinned image before deploying (this
  needs `--gpus all`; without a GPU the parser itself crashes).
- `ms_weights_peer` is removed. spark1 doesn't hold this model, so the role
  downloads from Hugging Face directly.

### Gap to the recipe

The recipe reports 97.7 tok/s on the same hardware and vLLM version; this
deployment does 77.1. The likely difference is `VLLM_USE_RUST_FRONTEND=1`,
which the recipe sets and the role can't, because `vllm.service.j2` has no
environment passthrough. Untested.

### Verify

```bash
ansible spark2 -m shell -a 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/health'   # 200
```

The play's own last task prints `spark2 serving qwen3.6-35b-a3b on port 8000`
after an authenticated `/v1/models`.

### Roll back

Revert `host_vars/spark2.yml` and re-run the same command. The Qwen3.8-27B
weights are still in `/opt/dgx-models`, so a rollback is a restart, not a
download.

### AnythingLLM on spark2

```bash
cd ansible && ansible-playbook site.yml --limit spark2 --diff 2>&1 | tee ../logs/site-spark2-allm-20261106.log
```

Two lines in `host_vars/spark2.yml`, the same role spark1 uses:

```yaml
allm_enabled: true
allm_llm_model: qwen3.6-35b-a3b
```

No key is entered by hand. The role takes the `anythingllm` entry from
`.secrets/vllm-keys.yml` and writes it into the container's environment, so
spark2's front end authenticates to spark2's vLLM with its own revocable
credential. vLLM was not restarted.

Verify that the container itself can reach and authenticate to vLLM, which is
the link the browser check doesn't cover:

```bash
ansible spark2 -b -m shell -a "docker exec anythingllm node -e 'fetch(process.env.GENERIC_OPEN_AI_BASE_PATH+\"/models\",{headers:{Authorization:\"Bearer \"+process.env.GENERIC_OPEN_AI_API_KEY}}).then(async r=>console.log(r.status,(await r.json()).data.map(m=>m.id)))'"
# 200 [ 'qwen3.6-35b-a3b' ]
curl -s -o /dev/null -w '%{http_code}\n' http://100.123.5.235:3001/api/ping   # 200, over the VPN
```

First visit to http://100.123.5.235:3001 runs AnythingLLM's own instance
setup. Accounts, workspaces and documents are separate from spark1's.

### Known issue: one engine crash, not reproduced

2026-11-06 16:09:34, on the first AnythingLLM traffic: vLLM's engine died with
`torch.AcceleratorError: CUDA error: unknown error` inside the hybrid model's
linear-attention layer (`mamba/gdn/qwen_gdn_linear_attn.py`,
`_forward_core_fused_norm`) while prefilling a 990-token prompt. systemd
restarted it (`NRestarts=1`) and it served again at 16:11:42. AnythingLLM
reports the gap as "The agent model failed to respond: Connection error".

What it was not:

- Not a driver or hardware fault: no NVRM/Xid line in `journalctl -k`.
- Not prompt length: prompts of 53 to 4,269 tokens all succeeded afterwards.
- Not a prefix-cache hit: the dump shows `hits=0` for that request.
- Not the agent request shape: seven streamed requests with four tools,
  thinking on, temperature 1.0 and concurrent pairs, all succeeded.

The crash dump is in the journal:

```bash
ansible spark2 -b -m shell -a "journalctl -u vllm --since '2026-11-06 16:09:30' --until '2026-11-06 16:09:40' -o cat"
```

If it recurs, `systemctl show vllm -p NRestarts` counts it. The flags the
recipe itself calls experimental on hybrid models, `--enable-prefix-caching`
and `--async-scheduling`, are the first suspects to drop from `ms_extra_args`;
moving to a newer vLLM image is the second.

It recurred 2026-11-08 00:02:54, now on vLLM 0.33.0, so the version upgrade
didn't fix it. Same signature: `CUDA error: unknown error` in
`qwen_gdn_linear_attn.py` (`_forward_core`, via `qwen3_next.py` and
`qwen3_5.py`), no Xid in the kernel log, one request running. Down 1 min 49 s,
back at 00:04:43.

| | 2026-11-06 16:09 | 2026-11-08 00:02 |
|---|---|---|
| vLLM | 0.28.0 | 0.33.0 |
| Front end | AnythingLLM | Open WebUI |
| Prompt tokens | 990 | 7,413 |
| Served from prefix cache | 0 | 6,336 |
| Newly prefilled this step | 990 | 1,077 |

*Table 20.3. Both crashes. Each hit the first or second real request from a
newly deployed front end.*

The second one was a prefix-cache hit (6,336 of 7,413 tokens already
computed), which points at the experimental hybrid-model prefix caching. The
first wasn't, so caching may not be the whole story.

Open WebUI shows the outage two ways. The request in flight gets "The server
had an error while processing your request." (vLLM's 500). Prompts sent while
vLLM is restarting get "Model '' was not found": Open WebUI can't fetch the
model list (`Connect call failed ('172.17.0.1', 8000)`), so the chat goes out
with no model. Both clear once vLLM is back.

#### Crash test and prefix caching off (2026-11-08)

A crash test replayed the shape of the second crash: six rounds of a fresh
~5k-token conversation, each followed by a ~5.8k-token turn that reuses most
of it from the cache. Thinking on, streamed, `max_tokens` 300.

| | Requests | Cache hit rate | Engine restarts |
|---|---|---|---|
| Prefix caching on | 12 | 32-39% once follow-ups started | 0 |
| Prefix caching off | 12 | not logged (off) | 0 |

*Table 20.4. The crash didn't reproduce with caching on, so the run after the
change shows nothing broke, not that the fault is fixed. Only time without a
recurrence can show that.*

Prefix caching is now off, explicitly, in `host_vars/spark2.yml`:

```yaml
- --no-enable-prefix-caching
```

Explicit because omitting `--enable-prefix-caching` leaves vLLM's own default
in charge. Verify against the engine's config dump, not the unit file:

```bash
ansible spark2 -b -m shell -a "journalctl -u vllm -o cat | grep -oE 'enable_prefix_caching=[A-Za-z]+' | tail -1"
# enable_prefix_caching=False
```

The cost is a re-prefill of shared prompt text on every turn, about a second
per 6k tokens at the measured ~6,000 tok/s. If the crash recurs with caching
off, `--async-scheduling` is next, then reporting it upstream with the dump
from `dump_input.py`.

The crash-test script lives in this session's scratchpad, not the repo. Its
pattern is the table above: varied filler text so rounds don't share a prefix,
then a follow-up that does.

### Replies cut off mid-thought: AnythingLLM's 1024-token cap

Symptom: a reply that is all reasoning and stops mid-sentence, with no answer.
Not a crash. vLLM counts it as `finished_reason="length"` in
`vllm:request_success_total`, and `NRestarts` doesn't move.

AnythingLLM's Generic OpenAI provider sends `max_tokens=1024` unless
`GENERIC_OPEN_AI_MAX_TOKENS` is set
(`/app/server/utils/AiProviders/genericOpenAi/index.js:41` and the agent
provider beside it). Fixed on spark2 in `host_vars/spark2.yml`:

```yaml
allm_extra_env:
  GENERIC_OPEN_AI_MAX_TOKENS: 16384
```

```bash
cd ansible && ansible-playbook site.yml --limit spark2 --diff 2>&1 | tee ../logs/site-spark2-allm-maxtokens-20261106.log
ansible spark2 -b -m shell -a 'docker exec anythingllm sh -c "echo \$GENERIC_OPEN_AI_MAX_TOKENS"'   # 16384
```

Raised to 81920 on 2026-11-07, see "vLLM 0.33.0 and an 81920 output cap".

Only the AnythingLLM container restarts; vLLM is untouched.

A thread that holds a failed turn, like the ones from the 16:09 crash, keeps an
empty assistant message in its history. The model then spends its reasoning
puzzling over the gap. Start a new thread rather than continuing one of those.

### presence_penalty as a server default

Qwen's card recommends `presence_penalty=1.5` in thinking mode to stop endless
repetition, which matters more as the output cap rises. AnythingLLM sends only
`temperature`, and vLLM's own defaults come from the model's
`generation_config.json`, which doesn't set it. So it goes on the server, in
`ms_extra_args`:

```yaml
- "'--override-generation-config={\"presence_penalty\":1.5}'"
```

A client that sends its own `presence_penalty` still wins. This restarts vLLM.

On the pinned v0.28.0 the flag is accepted but has no effect. vLLM merges the
override into the generation config, then copies only six keys into the
default sampling parameters (`vllm/config/model.py`, `get_diff_sampling_param`):
`repetition_penalty`, `temperature`, `top_k`, `top_p`, `min_p`,
`max_new_tokens`. The startup line that reports the defaults is the check:

```bash
ansible spark2 -b -m shell -a "journalctl -u vllm -o cat | grep 'sampling parameters have been overridden' | tail -1"
# v0.28.0: {'temperature': 1.0, 'top_k': 20, 'top_p': 0.95}   <- no presence_penalty
```

v0.33.0 adds `presence_penalty` and `frequency_penalty` to that list, so the
flag starts working once `ms_image` moves past 0.28.

### vLLM 0.33.0 and an 81920 output cap

```bash
cd ansible && ansible-playbook site.yml --limit spark2 --diff 2>&1 | tee ../logs/site-spark2-vllm033-20261107.log
```

2026-11-07. Two changes in `host_vars/spark2.yml`:

| Setting | Before | After |
|---|---|---|
| `ms_image` | `vllm/vllm-openai:v0.28.0` | `vllm/vllm-openai:v0.33.0` |
| `allm_extra_env.GENERIC_OPEN_AI_MAX_TOKENS` | 16384 | 81920 |

The upgrade is what makes `presence_penalty` work. 81920 is Qwen's output
length for "highly complex problems". Prompt plus output must fit in the
262144-token window or vLLM answers 400 (tested: 229376 accepted, 262130
rejected), so this leaves 180k for the prompt against AnythingLLM's 32768
prompt budget.

Before the switch, every flag in the unit was checked against
`vllm serve --help=all` in the new image, plus the `marlin` MoE backend,
the `qwen3_xml` tool parser, and the `qwen3` reasoning parser (registered in
`vllm/reasoning/__init__.py` rather than listed in help). `v0.33.0` and
`:latest` were the same image (`d825baf9ce4b`) on the day.

Verify:

```bash
ansible spark2 -b -m shell -a "journalctl -u vllm -o cat | grep 'sampling parameters have been overridden' | tail -1"
# {'presence_penalty': 1.5, 'temperature': 1.0, 'top_k': 20, 'top_p': 0.95}
ansible spark2 -b -m shell -a 'docker exec anythingllm sh -c "echo \$GENERIC_OPEN_AI_MAX_TOKENS"'   # 81920
```

| | v0.28.0 | v0.33.0 |
|---|---|---|
| Decode, single stream | 77.1 tok/s | 78.9 tok/s |
| Time to first token | 0.07 s | 0.06 s |
| Startup | 3 min 28 s | ~2 min 10 s |
| Weight load | 18.7 s | 6.9 s |

*Table 20.2. Same harness as table 20.1, presence_penalty 1.5. Three runs of
78.9 each; an explicit presence_penalty 0 gave the same 79.0, so the penalty
costs no decode speed.*

The first benchmark after the restart read 58.3 tok/s. That wasn't
the new version: AnythingLLM was generating at the same time (`Running: 2 reqs`
in the engine log) and the two streams split the decode. Check for concurrent
traffic before trusting a single-stream number:

```bash
ansible spark2 -b -m shell -a "journalctl -u vllm --since '-15min' -o cat | grep -E 'Running: [2-9] reqs'"
```

The same log gives a first look at concurrency: two streams together ran at
103-119 tok/s, against 79 for one.

Roll back by setting `ms_image` to `v0.28.0`, still on disk. The penalty goes
inert again with it.

The first attempt left out the outer single quotes and took spark2 down for
14 minutes, 17:20 to 17:34. systemd unquotes ExecStart words, double quotes included
even in the middle of a word, so vLLM received `{presence_penalty:1.5}`,
exited on the parse error, and systemd restarted it 19 times while the
playbook sat in its 15-minute health wait:

```
vllm serve: error: argument --override-generation-config: Value {presence_penalty:1.5} cannot be converted to <function loads ...>
```

Before redeploying, the quoting was checked with a throwaway unit rather than
by trial on vLLM:

```bash
ansible spark2 -b -m shell -a "printf '%s\n' '[Service]' 'Type=oneshot' 'ExecStart=/bin/echo ARG '\"'\"'--override-generation-config={\"presence_penalty\":1.5}'\"'\"'' > /run/systemd/system/quote-test.service && systemctl daemon-reload && systemctl start quote-test && journalctl -u quote-test -o cat | grep ARG | tail -1; rm -f /run/systemd/system/quote-test.service; systemctl daemon-reload"
# ARG --override-generation-config={"presence_penalty":1.5}
```

```bash
cd ansible && ansible-playbook site.yml --limit spark2 --diff 2>&1 | tee ../logs/site-spark2-presence-penalty-20261106.log
```

---

## 21. spark2 front end: AnythingLLM to Open WebUI `[spark2]`

```bash
cd ansible && ansible-playbook site.yml --limit spark2 --diff 2>&1 | tee ../logs/site-spark2-openwebui-20261107.log
```

2026-11-07. spark2's browser front end changed from AnythingLLM to Open WebUI
on the same port, so http://100.123.5.235:3001 still works. spark1 keeps
AnythingLLM.

| Piece | Change |
|---|---|
| `roles/openwebui/` | New role, same shape as `roles/anythingllm/` |
| `site.yml` | Runs `openwebui` after `anythingllm`, so the old front end frees port 3001 first |
| `host_vars/spark2.yml` | `allm_enabled: false`, `owui_enabled: true`, default model `qwen3.6-35b-a3b`, name `spark2` |
| `.secrets/vllm-keys.yml` | New `openwebui` key, so the front end has its own credential |
| vLLM on spark2 | `max_new_tokens: 81920` added to `--override-generation-config` |

*Table 21.1. What the switch touched. vLLM restarted once, for the new key
list and the output cap together.*

### Why the output cap moved into vLLM

AnythingLLM sent `max_tokens` itself (81920, from `GENERIC_OPEN_AI_MAX_TOKENS`).
Open WebUI sends none unless an admin sets one in a model's parameters, and
without a cap vLLM lets a reply run to whatever the 262144-token window leaves.
vLLM 0.33's `get_diff_sampling_param` renames a `max_new_tokens` override to
`max_tokens`, and the chat endpoint uses that default whenever a request omits
it (`vllm/entrypoints/openai/chat_completion/serving.py:183`). The cap now
covers every client, not just one front end.

### Facts checked against the image, not just the docs

The Open WebUI docs fetch left several points as summaries, so these were read
from the v0.13.0 source on spark2:

- `linux/arm64` image published for `v0.13.0`, 1.48 GB.
- `OPENAI_API_BASE_URLS` and `OPENAI_API_KEYS` are `;`-separated and fall back
  to the singular forms (`open_webui/config.py:325-337`).
- Those two, `ENABLE_OLLAMA_API`, `ENABLE_SIGNUP` and `DEFAULT_MODELS` are in
  the persistent-config map (`config.py:2934-3214`): seeded from the
  environment on first launch, then owned by the database.
- With no `WEBUI_SECRET_KEY`, `start.sh` writes one to
  `/app/backend/.webui_secret_key`, outside the `/app/backend/data` volume. The
  role therefore generates one into `/opt/openwebui/webui_secret_key` and
  passes it in, or every restart would log everyone out.
- `/health` returns `{'status': True}` unauthenticated (`main.py:3057`).

### Verify

```bash
curl -s http://100.123.5.235:3001/health                         # {"status":true}
ansible spark2 -b -m shell -a "journalctl -u vllm -o cat | grep 'sampling parameters have been overridden' | tail -1"
# {'presence_penalty': 1.5, 'temperature': 1.0, 'top_k': 20, 'top_p': 0.95, 'max_tokens': 81920}
ansible spark2 -b -m shell -a "systemctl is-active anythingllm; systemctl --failed --no-legend | wc -l"
# inactive / 0
```

The play itself confirms the hop the browser can't see: from inside the
container it lists vLLM's models with the URL and key Open WebUI was given, and
fails unless `qwen3.6-35b-a3b` is there.

First run: ok=42, changed=11, failed=0. A second run changes nothing in the
`openwebui` role; the only remaining `changed` is `model_server`'s image pull,
which matches "Pulling from" even when the image is already current.

### Two teardown fixes found on the way

Turning AnythingLLM off on spark2 was the first real use of the role's
teardown path, and it exposed two things, fixed in both front-end roles:

- systemd kept listing `anythingllm` under `systemctl --failed` after the unit
  file was gone, because stopping the container exits non-zero. Teardown now
  runs `systemctl reset-failed`.
- The container-removal task reported `changed` on every run, because
  `docker rm -f` exits 0 even when there is nothing to remove. It now keys off
  the output, which names the container only when one was removed.

### Things to know

- The first account created at http://100.123.5.235:3001 becomes the admin.
  Later sign-ups are `pending` until approved.
- Connection settings are seeded, not enforced. Rotating the `openwebui` key
  needs the admin UI (Settings, Connections) as well as `.secrets`, unless
  `owui_persistent_config: false` is set.
- AnythingLLM's spark2 data (1.7 MB: accounts, the few threads from
  2026-11-06) is still in `/opt/anythingllm`. Nothing was migrated; delete it
  by hand if it's not wanted.
- spark1 hasn't been redeployed. Its next run will add the `openwebui` key to
  its key list and pull `vllm/vllm-openai:latest` (0.33.0 by now), since only
  spark2 pins an image.

Roll back by flipping the two flags in `host_vars/spark2.yml`
(`allm_enabled: true`, `owui_enabled: false`) and re-running. The AnythingLLM
data is still in place. Put `GENERIC_OPEN_AI_MAX_TOKENS: 81920` back under
`allm_extra_env` too: AnythingLLM sends `max_tokens=1024` when it's unset, and
a value in the request beats vLLM's default.

---

## 22. spark1 takes over Qwen3.6 and Open WebUI `[spark1]`

```bash
cd ansible && ansible-playbook site.yml --limit spark1 --diff 2>&1 | tee ../logs/site-spark1-qwen36-20261108.log
```

2026-11-08. spark2 is due to be wiped, so spark1 now runs everything spark2
had built up in sections 20 and 21, and Qwen3.8-27B is retired.

`host_vars/spark1.yml` was rebuilt from `host_vars/spark2.yml`. Two values
differ, both on purpose:

| Setting | spark1 | spark2 |
|---|---|---|
| `ms_weights_peer` | `spark2-ic` | unset |
| `owui_name` | `spark1` | `spark2` |

*Table 22.1. The only differences between the two host_vars files, checked by
loading both as YAML and comparing every key.*

Everything else carries over: the NVFP4 model, vLLM pinned at `v0.33.0`, GPU
memory at 0.5, the recipe flags, prefix caching off, `presence_penalty` 1.5 and
`max_new_tokens` 81920 as server defaults, and Open WebUI replacing
AnythingLLM.

The 22 GB of weights came from spark2 over the interconnect: the peer-sync task
ran and the Hugging Face download was skipped. The task timestamps in
`logs/ansible.log` can't give a transfer time, because Ansible's async polling
skews them. Once spark2 is wiped the same setting falls back to a Hugging Face
download on a rebuild, so it needs no change.

### Verify

```bash
curl -s http://100.123.96.149:3001/health                     # {"status":true}
ansible spark1 -b -m shell -a "journalctl -u vllm -o cat | grep 'sampling parameters have been overridden' | tail -1"
# {'presence_penalty': 1.5, 'temperature': 1.0, 'top_k': 20, 'top_p': 0.95, 'max_tokens': 81920}
ansible spark1 -b -m shell -a "journalctl -u vllm -o cat | grep -oE 'enable_prefix_caching=[A-Za-z]+' | tail -1"
# enable_prefix_caching=False
ansible spark1 -b -m shell -a "systemctl is-active anythingllm; systemctl --failed --no-legend | wc -l"
# inactive / 0
```

| | spark1, Qwen3.8-27B FP8 (before) | spark1, Qwen3.6-35B-A3B NVFP4 |
|---|---|---|
| Decode, single stream | 8.4 tok/s | 80.3 tok/s |
| Time to first token | 0.14 s | 0.07 s |
| vLLM | 0.28.0 (`:latest`) | 0.33.0, pinned |
| Front end | AnythingLLM | Open WebUI |

*Table 22.2. Same harness as tables 20.1 and 20.2: three streamed runs of 512
tokens, thinking off, no other request in flight (checked for
`Running: 2 reqs` in the engine log).*

First run: ok=47, changed=12, failed=0.

### Things to know

- Clients that asked spark1 for `qwen3.8-27b` now get a 404 for that model
  name. spark1 had served nine requests under it since its previous restart.
- The Qwen3.8-27B weights are still in `/opt/dgx-models` (29 GB), and the old
  host_vars is in git history, so going back is a revert and a restart with no
  download. Delete the cache by hand once that's no longer wanted.
- spark1's AnythingLLM data, 1.2 MB and essentially the empty default
  database, is still in `/opt/anythingllm`.
- The first account created at http://100.123.96.149:3001 becomes the admin of
  spark1's Open WebUI. It's a separate instance from spark2's, with its own
  accounts and chats.
- The engine crash from section 20's known issue belongs to this model and
  configuration, so it moves to spark1 with them. `systemctl show vllm -p
  NRestarts` on spark1 counts it.

---

## 23. Bifrost gateway `[spark1]`

```bash
cd ansible && ansible-playbook site.yml --limit spark1 --diff 2>&1 | tee ../logs/site-spark1-bifrost-20261108.log
cd ansible && ansible-playbook telemetry.yml --limit spark1 --diff 2>&1 | tee ../logs/telemetry-spark1-bifrost-20261108.log
```

2026-11-08. Bifrost (`maximhq/bifrost:v2.5.0`) on spark1 port 4000: one
OpenAI-compatible endpoint in front of vLLM, a virtual key per client, and
per-client token and latency metrics in Thanos. Chosen over LiteLLM, whose
official images were trojaned on 2026-10-21 (v1.107.0) and which needs
Postgres for keys and spend tracking.

| Piece | Where |
|---|---|
| Role | `roles/bifrost/` (config.json, env file, unit, DOCKER-USER allowlist) |
| Node settings | `host_vars/spark1.yml`: `bifrost_enabled`, `bifrost_vllm_model`, `tel_extra_scrape_jobs` |
| Secrets | `.secrets/bifrost.yml` (admin, setup token, encryption key, virtual keys) and a `bifrost` entry in `.secrets/vllm-keys.yml` |
| Playbook | `site.yml` runs the role after `openwebui` and loads `.secrets/bifrost.yml` |
| Telemetry | scrape job `bifrost`; journald units now `openwebui` and `bifrost` instead of `anythingllm` |

*Table 23.1. What the gateway added.*

### Security posture

Bifrost's critical RCE (GHSA-86gf-xh3g-rvxq, fixed in 2.1.0) was reachable
because admin auth is off by default. Here:

- Dashboard and management API need the admin login (401 without it).
- Every inference request needs a virtual key (401 `virtual_key_required`
  without one, 401 `access_not_found` with a wrong one).
- The port is open to loopback, the Docker bridges and the VPN overlay only;
  from the lab LAN it times out.
- The encryption key is set from the first start. It can't be changed later
  without wiping the config store.
- Prompt and response bodies aren't stored (`disable_content_logging`).

### Problem found on the way: SSRF guard blocks the Docker gateway

The first deploy came up healthy, but every request through it returned:

```
502 "connection to private IP 172.17.0.1 is not allowed"
```

Bifrost refuses provider connections to RFC 1918 addresses by default, and
`host.docker.internal` resolves to the Docker gateway. The v2.5.0 schema
(`transports/config.schema.json`, `$defs.network_config`) has
`allow_private_network` for this, set on the vLLM provider only. Host
networking would also work, since loopback is always allowed, but it would
bypass the DOCKER-USER allowlist.

### Problem found on the way: telemetry runs depended on GitHub

`telemetry.yml` failed twice: a read timeout, then a truncated package
("E:read, still have 8 to read but none left"). GitHub's release download was
returning 504. The role's `apt: deb: <url>` downloads the package before it
compares versions, so even a config-only run needed GitHub. The role now
checks the installed version first and skips the download when it already
matches.

### Verify

Acceptance test from desktop2 over the VPN, 13 of 13:

| Check | Result |
|---|---|
| `/health`, no auth | 200 |
| `/metrics`, no auth | 200, 57+ `bifrost_` series |
| Inference with no key / wrong key | 401 / 401 |
| Inference with the virtual key at `/v1`, `/openai/v1`, `/openai` | 200 |
| `/v1/models` with the virtual key | `vllm/qwen3.6-35b-a3b` |
| Management API without / with admin auth | 401 / 200 |
| 3,500-token non-streaming reply | 200 after 56 s, past any 30 s default |
| Port from the lab LAN | timed out (firewall) |
| Token metrics | labelled `virtual_key_name="desktop2-opencode"` |

*Table 23.2. Only `/v1` passed `chat_template_kwargs` through to vLLM; the
`/openai` routes didn't, so `/v1` is the documented base URL.*

In Thanos afterwards: `up{job="bifrost"} = 1` and token counts by
`virtual_key_name` and `model`. In Loki: `bifrost.service` and
`openwebui.service` lines.

A second `site.yml` run changed nothing in the role. Restarts were 0 for vLLM,
Open WebUI and Bifrost, and DOCKER-USER held the five `bifrost-acl` rules.

```bash
curl -s http://100.123.96.149:4000/health
ansible spark1 -b -m shell -a "iptables -S DOCKER-USER | grep -c bifrost-acl"   # 5
```

### Things to know

- The client base URL is `http://100.123.96.149:4000/v1`, the model is
  `vllm/qwen3.6-35b-a3b`, and the key is that client's virtual key. See
  `ACCESS.md`, "Pointing a client at the gateway".
- `bifrost_cost_total` isn't emitted for a self-hosted model, so attribution
  is in tokens, not dollars.
- Adding the `bifrost` key restarted spark1's vLLM once.
- spark2 isn't touched. Its telemetry config still lists `anythingllm` until
  `telemetry.yml` runs there, which is moot once it's wiped.

### spark1 Open WebUI through Bifrost

```bash
cd ansible && ansible-playbook site.yml --limit spark1 --diff 2>&1 | tee ../logs/site-spark1-owui-via-bifrost-20261108.log
```

spark1's Open WebUI now reaches vLLM through Bifrost rather than directly, so
its chats are counted alongside every other client. It's all `host_vars` and
secrets; the role didn't change:

| Setting | Value |
|---|---|
| `owui_llm_base_url` | `http://host.docker.internal:4000/v1` |
| `owui_llm_api_key` | virtual key `spark1-openwebui` (new, in `.secrets/bifrost.yml`) |
| `owui_default_model` | `vllm/qwen3.6-35b-a3b`, Bifrost's id for the model |

*Table 23.3. Open WebUI's connection, before: `host.docker.internal:8000/v1`
with the `openwebui` vLLM key.*

`site.yml` now runs `bifrost` straight after `model_server`, ahead of the front
ends. Open WebUI's link check would otherwise run before Bifrost had loaded the
new virtual key, and fail.

Open WebUI's database was checked first: `openai.api_base_urls` and
`ui.default_models` were unset there, so the environment applies and the
change took effect without touching the admin UI. Its play confirmed the new
link from inside the container (`vllm/qwen3.6-35b-a3b` listed through
Bifrost).

### opencode against the gateway

Tested from desktop2 with opencode 2.2.6, using a throwaway project config and
`--standalone` so the user's own opencode server and sessions weren't touched.
The model listed as `bifrost/vllm/qwen3.6-35b-a3b`, a one-word request
returned `pong`, and Bifrost logged it under `desktop2-opencode` with
`app=OpenCode`. The client config is in `ACCESS.md`.

---
