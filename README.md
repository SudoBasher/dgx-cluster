# dgx-cluster

Building stuff on a local DGX cluster: two DGX Sparks (`spark-a01a`,
`spark-9d80`) joined by a 200GbE ConnectX-7 link.

| Document | Contents |
|---|---|
| [ACCESS.md](ACCESS.md) | How to reach everything: VPN, overlay IPs, SSH, web interfaces |
| [RUNBOOK.md](RUNBOOK.md) | Every command needed to rebuild a node from stock DGX OS, in replay order |
| [FINDINGS.md](FINDINGS.md) | Measured performance: memory bandwidth, interconnect, NCCL, and what it means for model serving |
| [MONITORING.md](MONITORING.md) | Dashboards, streaming commands, health checks |
| [CLOUD_ARCHITECTURE.md](CLOUD_ARCHITECTURE.md) | AWS VPN and observability design: NetBird, Thanos, Loki, Grafana. Designed, not yet built |
| [NEXT_STEPS.md](NEXT_STEPS.md) | Open work, and decisions already made so they don't get relitigated |
| [ansible/](ansible/README.md) | vLLM deployment: one model server per node, repointable independently |
| `bench/` | Benchmark sources: `gpubw.cu`, `allreduce_bw.cu`, `run_allreduce.sh` |

Access is via a keypair kept in `.ssh/` in this repository, not `~/.ssh`:

```bash
ssh -F .ssh/config spark1
ssh -F .ssh/config spark2
```

## Headline numbers

| | |
|---|---|
| GPU memory bandwidth | 261 GB/s per node, 96% of theoretical |
| Interconnect, raw RDMA | 196 Gb/s using both host paths |
| Interconnect latency | 1.66 µs |
| NCCL all-reduce | 3.0 GB/s, limited by the absence of GPUDirect RDMA |
| Combined memory | 242 GiB unified across the pair |
| Serving | Qwen3.8-27B FP8, one replica per node, 4-8 tok/s |
| Observability | Thanos + Loki + Grafana in us-west-2, 12-month retention |
| Access | NetBird VPN; nothing public except the VPN control plane |

The NCCL figure is the binding constraint for multi-node inference. See
`FINDINGS.md`.
