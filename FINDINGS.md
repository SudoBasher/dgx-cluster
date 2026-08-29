# Performance characterisation: two-node DGX Spark cluster

Measurements taken 24–25 August 2026 on `spark-a01a` and `spark-9d80`.

## Summary

The pair is joined by a single 200GbE cable and behaves as follows. Per-node GPU
memory bandwidth is 261 GB/s, or 96% of the LPDDR5X theoretical maximum. The
interconnect carries 196 Gb/s of raw RDMA traffic, close to line rate. NCCL
collectives, however, reach only 3.0 GB/s (24 Gb/s), about a fifth of the wire,
because GPUDirect RDMA does not work on GB10.

That last figure is the one that matters for multi-node inference. It is low
enough to rule out tensor parallelism for anything but short prompts, and it
cannot be tuned around.

A second cable would not help. Memory moves four to six orders of magnitude more
data per token than the network does, and the network is already limited by
software rather than by the wire.

## System

| | |
|---|---|
| Nodes | `spark-a01a` (10.255.194.68), `spark-9d80` (10.255.195.149) |
| SoC | NVIDIA GB10, 48 SMs, compute capability 12.1 |
| Memory | 121 GiB LPDDR5X-8533, 256-bit, unified CPU/GPU |
| Storage | 3.7 TB NVMe, 3.5 TB free |
| OS | DGX OS on Ubuntu 24.04, kernel 6.17.0-1014-nvidia, aarch64 |
| Driver | 580.142 |
| Interconnect | ConnectX-7, one 1 m Amphenol DAC, 200 Gb/s |

Both nodes are configured identically and measured within 0.5% of each other on
every test.

## Memory bandwidth

Theoretical peak is 273 GB/s (8533 MT/s × 256 bit ÷ 8).

Measured with BabelStream-style kernels over 2 GiB arrays, compiled `-O3
-arch=sm_121` in a CUDA 13.0 container. Source: `bench/gpubw.cu`.

| Kernel | spark-a01a | spark-9d80 |
|---|---|---|
| Copy (1 read + 1 write) | 251.8 GB/s | 251.5 GB/s |
| Mul (1 read + 1 write) | 251.2 GB/s | 251.2 GB/s |
| Triad (2 reads + 1 write) | 247.5 GB/s | 247.2 GB/s |
| Read only | 261.4 GB/s | 261.6 GB/s |

Read bandwidth is the relevant figure for inference, since decoding streams
weights out of memory. At 261 GB/s the kernels achieve 96% of theoretical, so
there is no headroom to recover.

For comparison, a 20-thread OpenMP STREAM on the CPU side reaches 122 GB/s copy
and 91–97 GB/s read. The CPU cannot saturate the bus the GPU shares with it;
CPU figures are relevant only to host-side preprocessing.

## Interconnect

### Topology

One cable joins the two nodes. Linux presents two network devices that reach it,
on separate PCIe domains:

| Device | PCI address | RoCE device | Address |
|---|---|---|---|
| `enp1s0f0np0` | 0000:01:00.0 | `rocep1s0f0` | 192.168.100.x |
| `enP2p1s0f0np0` | 0002:01:00.0 | `roceP2p1s0f0` | 192.168.101.x |

The `f1` device on each controller is unpopulated (`carrier=0`). Because the two
paths sit on different PCIe domains, each has its own x4 link, and driving both
concurrently nearly doubles host-side throughput even though they share one wire.

### Throughput

| Test | Result |
|---|---|
| TCP, 8 streams, one path | 111 Gb/s, no retransmits |
| RDMA write, 1 QP, 64 KB, one path | 109 Gb/s |
| RDMA write, 4 QP, 1 MB, one path | 112 Gb/s |
| RDMA write, both paths concurrently | 98 + 98 = 196 Gb/s |

A single path is limited to 112 Gb/s by PCIe, not by the cable:

```
$ sudo lspci -vv -s 0000:01:00.0 | grep -E 'LnkCap:|LnkSta:'
  LnkCap: Port #0, Speed 32GT/s, Width x4, ASPM not supported
  LnkSta: Speed 32GT/s, Width x4
```

Gen5 x4 is 126 Gb/s raw and 110–115 Gb/s after protocol overhead. The limit
appears in `LnkCap`, so x4 is the device maximum and no firmware setting widens
it. Queue-pair count and message size have no effect: 1 QP at 64 KB and 4 QPs at
1 MB both land near 110 Gb/s.

Driving both paths reaches 196 Gb/s, roughly 98% of the wire. At that point the
cable is the constraint rather than PCIe. Each path drops from 112 to 98 Gb/s
under concurrent load, so the gain is 1.75×, not 2×.

### Latency

| Method | Round trip |
|---|---|
| `ib_send_lat` (RDMA) | 1.66 µs typical, 1.77 µs p99 |
| `ping` (ICMP) | 1.25 ms |

ICMP traverses the kernel network stack and is not representative. NCCL uses
RDMA, so 1.66 µs is the figure that applies. It is a normal value for a 1 m DAC
and needs no tuning. The CPU governor is already `performance` and interrupt
coalescing is 8 µs, neither of which could account for a millisecond.

### Loop safety

A single wire cannot form a loop, and nothing bridges the two network devices in
any case. `bridge link show` lists neither, and they occupy separate IP subnets,
so frames are never relayed between them. After a full-rate concurrent run both
nodes reported zero rx errors, zero drops, and no multicast over a 2 s window.

Do not place the two devices in a Linux bond or bridge. They share one wire, so a
bond gains nothing, and bridging is what would create a loop. Should a cable ever
be added to the empty `f1` cage, recheck this.

## NCCL collectives

Measured with `bench/allreduce_bw.cu`: two ranks, one GPU each, NCCL 2.27.7 over
RoCE. Bootstrap uses a hex-encoded `ncclUniqueId` passed from rank 0 to rank 1,
which avoids needing MPI.

| Configuration | All-reduce bandwidth |
|---|---|
| TCP fallback (`NET/Socket`) | 1.50 GB/s |
| RDMA, one HCA | 1.53 GB/s |
| RDMA, both HCAs | 3.04 GB/s |
| Both HCAs plus 16 channels, 8 QPs, 16 MB buffers | 3.03 GB/s |
| `ib_write_bw` on the same wire, for reference | 14 GB/s |

Small-message times:

| Payload | All-reduce |
|---|---|
| 4 KB | 18 µs |
| 16 KB | 25 µs |
| 32 KB | 33 µs |
| 64 KB | 52 µs |
| 1 MB | 625 µs |

NCCL therefore achieves 21% of what the wire delivers to `ib_write_bw`, and 3.0
GB/s is a hard ceiling: adding channels, queue pairs, `NCCL_IB_SPLIT_DATA_ON_QPS`
and larger buffers changed nothing.

Using both HCAs is the only change that helped, doubling 1.53 to 3.04 GB/s.

### Cause

NCCL reports `GDR 0` in every configuration, meaning GPUDirect RDMA is inactive
and all traffic is staged through host memory. `nvidia-peermem.ko` ships with the
580.142 driver but will not insert:

```
$ sudo modprobe nvidia_peermem
modprobe: ERROR: could not insert 'nvidia_peermem': Invalid argument
```

There is no `/sys/kernel/mm/memory_peers/`, and neither `NCCL_NET_GDR_LEVEL=SYS`
nor `NCCL_NET_GDR_READ=1` changes the result. This appears inherent to GB10's
unified memory design, where the classic peer-memory path does not apply. Until
NVIDIA ships a working GDR or DMA-BUF path, 3.0 GB/s should be treated as the
platform's cross-node collective ceiling.

The 25 µs cost of a 16 KB all-reduce against a 1.66 µs raw round trip reflects
the same staging overhead, roughly 15×.

### Container requirement

A container running NCCL must have `libibverbs1` and `ibverbs-providers`
installed. Without them NCCL falls back to `NET/Socket` and reports 1.5 GB/s
while otherwise appearing healthy. The stock `nvidia/cuda` images do not include
them. Check `NCCL_DEBUG=INFO` output for `Using network IB` rather than `Using
network Socket`.

## Implications for model serving

The following assumes a model with roughly 100 layers, hidden dimension 8192, and
two all-reduces per layer, holding about 200 GB of 4-bit weights. Those
parameters are estimates for an unspecified model, so the magnitudes matter more
than the exact figures.

### Decode

Tensor parallelism splits every layer across both nodes, so the two weight shards
are read concurrently. Pipeline parallelism splits by layer, so they are read in
sequence.

| | TP=2 | PP=2 |
|---|---|---|
| Weight read per token | 100 GB concurrent | 100 GB then 100 GB |
| Communication per token | 200 × 25 µs ≈ 5 ms | ~16 KB once, negligible |
| Dense model | ~2.6 tok/s | ~1.3 tok/s |
| MoE, 10% active | ~23 tok/s | ~13 tok/s |

TP is about twice as fast, and its 5 ms of communication is between 1% and 13% of
a decode step.

### Prefill

Tensor parallelism all-reduces the full activation tensor at every layer. For an
8192-token prompt that is 8192 × 8192 × 2 B = 134 MB per all-reduce, or about
27 GB per prefill.

| | Traffic | Time at 3 GB/s |
|---|---|---|
| TP=2 | ~27 GB | ~9 s |
| PP=2 | ~134 MB | ~45 ms |

The 3 GB/s ceiling makes TP prefill impractical. With working GDR at 14 GB/s it
would be about 2 s, still poor but usable.

### Recommendation

Pipeline parallelism for interactive use with long prompts: a 9-second prefill
penalty per request outweighs any decode advantage. Tensor parallelism only if
prompts are short and generations long. Adding microbatching to PP=2 keeps both
nodes busy and recovers most of TP's decode advantage without the prefill cost.

The choice interacts with the serving stack. llama.cpp's RPC backend splits by
layer, which is pipeline-style. vLLM supports both.

### On a second cable

Not worth buying. Per token, memory moves tens of GB while the interconnect moves
16 KB under PP or a few MB under TP, a ratio of 10⁴ to 10⁶. The network is also
already software-limited at 21% of the wire, so widening the wire addresses the
wrong bottleneck. Latency is not a reason either: parallel links add width, not
speed.

The second QSFP cage is genuinely empty and a second cable would attach. Whether
it would add usable bandwidth is untested, and given how often this hardware has
defeated prediction, it should be measured with a borrowed cable rather than
assumed.

## Measurement notes

Three standard diagnostics give wrong answers on this hardware.

**LLDP** reports neighbours on ports that are not cabled. The ConnectX-7
advertises `switchid 1ba029000347bb4c`, and `spark-a01a` port 0 lists
`spark-a01a` port 1 as a neighbour. Every port appears to see every other port.

**Transceiver EEPROM** is not per-port. All four ports on both machines report
`Vendor SN: APF26299117RRB`, an Amphenol 1 m part identifying as QSFP28 despite
the ports negotiating 200000 Mb/s. Four cable ends cannot share one serial.

**ARP and ping** succeed on both paths with distinct MACs on distinct devices,
which is indistinguishable from two separate cables.

The reliable method is PHY byte counters, which count what crosses the wire.
Pushing traffic on one path only and reading the other distinguishes shared from
separate wires:

```
$ ethtool -S enp1s0f0np0   | grep tx_bytes_phy
$ ethtool -S enP2p1s0f0np0 | grep tx_bytes_phy
```

With one wire both devices report byte-identical counters. Measured 503320994844
on both, then 645532323788 on both after a 142 GB transfer driven entirely
through the second device.

## Deployed performance, Qwen3.8-27B FP8

Measured 27 August 2026 on the live deployment (`ansible/`), one replica per
node, vLLM in the `vllm/vllm-openai:latest` container.

| Measurement | Result |
|---|---|
| Throughput | 4.3-8.4 tok/s across samples |
| Effective memory bandwidth | ~141 GB/s, about 54% of the 261 GB/s peak |
| Cold start | ~7 minutes (66 shards, then torch.compile and CUDA graphs) |
| Weight load rate | ~165 MB/s, NVMe-bound |
| Context | 262144, confirmed by `/v1/models` |

Predicted throughput was 6-8 tok/s. The first careful sample came in at 5.05,
and later samples ranged 4.3-8.4 depending on generation length and warmth. The
estimate was optimistic because it assumed decode achieves peak memory
bandwidth; vLLM reaches roughly 54% of it.

### Reasoning overhead dominates short answers

Qwen3.8 is a reasoning model. With `--reasoning-parser qwen3` the chain of
thought is stripped from `content` and only counted in
`usage.completion_tokens_details.reasoning_tokens`, but it is still generated
and still costs time.

| Prompt | Answer tokens | Reasoning tokens | Wall time |
|---|---|---|---|
| "Name three primary colours" | 8 | 54 | 7.4 s |
| "Write a haiku" | 19 | 167 | ~37 s |

Roughly 90% of generation is thinking the user never sees. For interactive use
this matters more than the raw token rate: a three-word answer takes seven
seconds. Disable thinking per request with
`chat_template_kwargs: {"enable_thinking": false}` where the client supports it.

Without the reasoning parser the thinking is returned inline as message content
and can consume the entire token budget before the answer begins. The first
deployment did exactly that.

### Operational notes

The container writes the HF cache as root at mode 600 in places, regardless of
who owns the directory. Any process reading that cache as a normal user, such
as an rsync to a peer node, fails until ownership is normalised.

torch.compile output goes to `/root/.cache/vllm`. With `--rm` and no volume for
it, every restart recompiles from scratch, several minutes each time. It needs
its own mount separate from the HF cache.

Weight transfer between nodes over the interconnect runs at 3.83 Gb/s
(479 MB/s), SSH-encryption-bound rather than wire-bound, so about 3% of the
link. That still moves 29 GB in roughly a minute, against 8-40 minutes to
re-download. Worth doing; not worth optimising further at this model size.

---

## Superseded conclusions

Recorded because each was wrong in a way that changed a decision.

1. *Two cables.* Inferred from a successful ping between the second pair of
   ports. A ping proves layer-2 reachability, not a physical cable.
2. *196 Gb/s proves two independent paths.* 196 Gb/s is line rate for one 200G
   wire, which fits the single-cable reading better.
3. *Latency is 1.1 ms, so prefer PP.* That was ICMP. RDMA latency is 1.66 µs.
4. *TP is therefore faster than PP.* True for decode, but measuring NCCL revealed
   a 3 GB/s collective ceiling that makes TP prefill roughly 9 s on an 8k prompt
   against 45 ms for PP.

5. *Decode will run at 6-8 tok/s.* Measured 4.3-8.4, first careful sample 5.05.
   The estimate assumed decode saturates memory bandwidth; vLLM achieves about
   54% of it.

In each case reasoning from a component specification, whether ping, raw RDMA
latency, wire rate, or PCIe width, predicted the wrong outcome. Only end-to-end
measurement of the actual collective settled it. The tok/s estimates above are
themselves derived rather than measured and deserve the same scepticism until a
real model is benchmarked.

## Reproduction

Benchmark sources are in `bench/`. Build and run procedures are in `RUNBOOK.md`,
Phase 4b for memory bandwidth and Phase 8 for NCCL.

Three CUDA 13 portability issues arose while writing `bench/gpubw.cu`:

- `cudaDeviceProp::memoryClockRate` was removed. Use `cudaDeviceGetAttribute`
  with `cudaDevAttrMemoryClockRate`.
- That attribute reports the data rate in MT/s. Applying a further ×2 for DDR
  double-counts and yields 546 GB/s instead of 273.
- A `CHECK` macro whose internal variable is named `e` shadows caller variables
  passed by address, so `CHECK(cudaEventCreate(&e))` fails with a misleading
  overload-resolution error.
