# Next steps

Open work on the cluster, roughly in priority order. Current state is in `FINDINGS.md`; procedures are in `RUNBOOK.md` and `ansible/README.md`.

## 0. Cloud stack — built

Complete as of 2026-09-03. VPC, NetBird VPN, Thanos, Loki, Grafana, telemetry agents on all four hosts, three dashboards, lab VLAN route, and the access policies with the All-to-All default disabled. Addresses in `ACCESS.md`.

Everything is Ansible or OpenTofu; there are no configuration shell scripts. `ansible/netbird-access.yml` holds the access model declaratively and converges to `changed=0`.

Two things learned the hard way, recorded so they are not repeated:

**Policies must cover machine-to-machine paths.** Disabling the All-to-All default with only human-access policies took telemetry to zero, silently. The collectors pushing to Thanos and thanos-query reaching thanos-receive both needed explicit policies. Check target counts after any policy change, not just your own access.

**netbird-b was built and then destroyed.** It was justified by a `Relayed` reading between the Sparks and AWS, but registering it required the `relays:` block that caused an outage, and giving the observability nodes EIPs removed the relay dependency anyway. That fix is now confirmed by measurement: the Spark-to-obs-write link reports `Connection type: P2P` with `srflx/srflx` candidates at 32 ms, against 82 ms relayed. Do not rebuild netbird-b without new evidence.

## 1. vLLM authentication — done

Complete as of 2026-09-04. Both nodes require a key on `/v1`, and the published port is restricted to the VPN overlay.

Five per-client keys in `.secrets/vllm-keys.yml`, loaded by `site.yml`: `admin-tommy`, `claude`, `anythingllm`, `openwebui` (added 2026-11-07), `teammate`. Any one can be revoked by deleting its entry and re-running the playbook.

Two things learned:

**All keys go on a single `--api-key` flag.** It is `nargs='+'`, so repeating the flag keeps only the last value and every other client gets 401 — with no warning at startup.

**Keys are not a perimeter.** `--api-key` guards `/v1`, `/v2` and `/inference` only; `/invocations` offers the same inference unauthenticated. What actually closes that is `ms_allowed_cidrs`, enforced in DOCKER-USER. Clients on the lab LAN must now join the VPN; widen that list if a lab host genuinely needs direct access.

## 2. Disable thinking by default

Measured on Qwen3.8-27B, retired 2026-11-08; Qwen3.6 reasons the same way. Qwen3.8 is a reasoning model and roughly 90% of generated tokens are chain of thought the user never sees. "Name three primary colours" spends 54 reasoning tokens on an 8-token answer, about seven seconds. This is more noticeable in practice than the raw 4-8 tok/s.

Options: a per-request `chat_template_kwargs: {"enable_thinking": false}`, which requires client support, or a server-side default in the role so short queries return promptly and reasoning is opted into rather than out of.

## 3. Benchmark throughput properly

Measured samples ranged 4.3-8.4 tok/s, which is too wide to plan around. The spread is some mix of warmth, generation length and sampling noise, and has not been separated. A short sweep over fixed prompt and output lengths, warm, on both nodes, would give a number worth quoting. Concurrency behaviour is also untested: vLLM batches continuously, so aggregate throughput under several simultaneous requests should be well above the single-stream figure.

## 4. Repoint spark2 at a second model

Done 2026-11-06: spark2 serves `nvidia/Qwen3.6-35B-A3B-NVFP4` as `qwen3.6-35b-a3b` (`RUNBOOK.md` section 20). The nodes are now separate endpoints rather than replicas: spark1 for depth, spark2 for speed.

## 5. Connect AnythingLLM

Done, then replaced. Both Sparks now run Open WebUI pre-wired to their own vLLM (`ansible/README.md`). AnythingLLM ran on spark1 from 2026-09 and on spark2 from 2026-11-06; spark2 switched on 2026-11-07 (`RUNBOOK.md` section
21) and spark1 on 2026-11-08 (section 22).

## 7. Re-test GPUDirect RDMA after any driver update

NCCL cross-node collectives are capped at 3.0 GB/s, about 21% of the wire, because `nvidia-peermem.ko` will not insert on GB10 and NCCL falls back to staging through host memory. If a future driver makes `modprobe nvidia_peermem` succeed, re-run `RUNBOOK.md` section 9b. A working GDR path would raise the ceiling toward 14 GB/s and make tensor parallelism across nodes viable, which would change the serving topology advice.

## Decided against

Recorded so these do not get relitigated.

**A second interconnect cable.** Per token, memory moves 10^4 to 10^6 times more bytes than the network. The link is also already software-limited at 21% of the wire by the missing GDR path, so widening it addresses the wrong bottleneck. The second QSFP cage is empty and a cable would attach, but measure with a borrowed one before buying.

**Tensor parallelism across nodes.** Roughly 27 GB of wire traffic for an 8k-token prefill, about 9 seconds at 3.0 GB/s, against 45 ms for pipeline parallel. Never raise `ms_tensor_parallel_size` above 1.

**A load balancer in front of both nodes.** Superseded: Bifrost now fronts spark1 (`RUNBOOK.md` section 23). With spark2 due to be wiped it routes to a single backend; its value is per-client attribution and one endpoint, not balancing.

**bf16 weights.** Capacity-limits the cluster to about 110B parameters and doubles memory traffic on hardware where decode is bandwidth-bound. FP8 is the quality-preserving default here.
