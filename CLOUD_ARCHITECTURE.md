# Cloud architecture: VPN and observability

Design for the AWS side of the cluster, agreed 2026-08-27 and **built
2026-09-02**. Operational addresses are in `ACCESS.md`; build steps are in
`RUNBOOK.md` sections 11-14.

Two related goals. Ship all logs and metrics from the Sparks to a long-retention
store with a fast Grafana front end, and give people remote access to both the
lab and the cloud without exposing either to the internet.

Region us-west-2. All infrastructure new. Open source throughout — no AWS
proprietary networking or observability services.

## Summary

| Layer | Choice |
|---|---|
| VPN | NetBird, self-hosted, single control-plane node to start |
| Metrics | Thanos with S3 backend |
| Logs | Loki with S3 backend |
| UI | Grafana |
| Agent | OpenTelemetry Collector on each Spark |
| Retention | 12 months, expanding to 3 years |
| Cost | ~$279/month |

## Network plan

| Range | Use |
|---|---|
| `10.200.0.0/16` | AWS VPC (new) |
| `100.64.0.0/10` | NetBird overlay |
| `10.255.128.0/20` | Lab VLAN, tommyslab, UniFi Dream Machine |
| `10.255.192.0/20` | Separate lab segment, not routable from the Sparks |
| `192.168.100.0/24`, `192.168.101.0/24` | Spark interconnect, private cable |
| `172.17.0.0/16` | Docker on the Sparks |

No overlaps. Confirm before changing any of them.

## VPN

NetBird, self-hosted. Both clients and control plane are BSD-3 licensed, with
first-party clients for Linux, macOS, iOS, Android and Windows. Since v0.65 the
server ships as a single container.

Note on naming: NetBird's "Public API" means publicly documented, not publicly
hosted. Self-hosted it runs on our management server. Nothing reaches
netbird.io.

### Topology

One control-plane node in the public subnet running management, signal,
dashboard, Dex, coturn, and NAT for the private subnet.

**Every host is a NetBird peer, including the observability nodes.** There is no
routing peer for the VPC CIDR and no route table entry for the overlay. Reaching
Grafana is a direct peer-to-peer WireGuard tunnel that does not depend on the
control-plane node being alive. Routing peers exist for hosts that cannot run a
client; we have none.

The lab VLAN is reached differently, because the UDM and other lab hosts cannot
run a client. Both Sparks advertise `10.255.128.0/20` as a network route, giving
failover if one is rebooted.

Since the UDM is under our control, add a static route for `100.64.0.0/10`
pointing at the routing peer rather than letting NetBird masquerade. Source
addresses are then preserved in firewall logs.

### Access policy

| From | To | Allowed |
|---|---|---|
| admins | sparks | all |
| admins | lab network `10.255.128.0/20` | all |
| admins | aws-infra | all |
| teammates | sparks | all |
| teammates | lab network `10.255.128.0/20` | all |
| teammates | obs-read peer | TCP 3000 only |

Teammates get full lab access and exactly one cloud port: Grafana. Scope that
policy to the `obs-read` peer, not the `aws-infra` group, or it would permit
port 3000 on any AWS host.

### Automation

A dedicated service user with a personal access token against the NetBird API
covers user creation and revocation, setup keys for device enrolment, groups and
policies. Setup keys are the mechanism for onboarding a machine without a human
in the dashboard.

Identity starts with the embedded Dex. Any OIDC provider can replace it later
without redesign.

## Observability

### Signals

| Source | Interval | Series (both nodes) |
|---|---|---|
| node_exporter | 1s | ~2,400 |
| DCGM exporter | 1s | ~100 |
| Interconnect PHY counters | 1s | ~40 |
| Collector self-telemetry | 1s | ~100 |
| vLLM `/metrics` | 5s | ~800 |
| journald: vllm, anythingllm, docker, kernel | stream | — |

Roughly 3,440 series and 88.3 billion samples a year. Ingest is 2,800
samples/second, which is small; the scale problem is query, not write.

vLLM is scraped at 5s rather than 1s because its metrics handler runs inside the
serving process, and 60 invocations a minute against a node already at 105 of
121 GiB risks perturbing the thing being measured. Verify inference latency with
the scrape on and off.

Traces are deliberately out of scope for v1. vLLM's OTLP support needs
verifying, and with two nodes and no distributed call graph the insight does not
justify the complexity.

### Storage and retention

Thanos rather than Mimir, specifically for automatic multi-resolution
downsampling. A one-year query over raw 1s data is 31.5 million points per
series; against 5-minute rollups it is about 105,000. No instance size fixes
that, and hand-written recording rules only cover metrics anticipated in
advance, leaving ad-hoc exploration slow.

| Resolution | Retained | Purpose |
|---|---|---|
| Raw 1s | 30 days | Incident forensics |
| 5 minute | 12 months | Normal dashboard range |
| 1 hour | 3 years | Capacity trends |

Storage is dominated by the 30-day raw window at roughly 9 GB. Three years of
rollups add well under a gigabyte. With logs, the whole thing is about 55 GB in
S3, roughly $2 a month.

**An S3 Gateway VPC Endpoint is required, not optional.** It is free, and it
keeps every block flush and chunk fetch off the NAT instance. Without it all
object-storage traffic would traverse the control-plane node.

### Split read from write

Two nodes, same AZ so there are no cross-AZ transfer charges and inter-node
latency is sub-millisecond.

The reason is compaction, not ingest. Building 5-minute and 1-hour rollups from
88 billion raw samples a year is bursty and CPU-hungry. On a single node that
work would land on top of queries and make dashboards intermittently sluggish.

Splitting also means a pathological query cannot stall ingest and drop samples,
and the query side can be restarted without losing metrics.

Push, not pull: collectors write out to Thanos Receive over the VPN, so nothing
needs inbound access to the lab.

### Query performance

Memcached in front of Thanos Store and Loki. Cardinality discipline at the
collector — with three-year retention a careless label is permanent. Drop the
noisier node_exporter collectors rather than storing them for three years.

## Instances

| Node | Subnet | Roles | Spec | Monthly |
|---|---|---|---|---|
| netbird-cp | public | management, signal, dashboard, Dex, coturn, NAT | m7g.large | ~$43 |
| obs-write | private | Thanos Receive, compactor, Loki write | r7g.xlarge | ~$98 |
| obs-read | private | Thanos Query + Store, Loki read, Grafana, memcached | r7g.xlarge | ~$98 |
| EBS | | 300 + 150 + 30 GB gp3 | | ~$38 |
| S3 | | growing to ~55 GB | | ~$2 |
| **Total** | | | | **~$279** |

netbird-cp is non-burstable deliberately: a t-class instance exhausting CPU
credits would degrade NAT and relay together. It needs source/dest check
disabled, a default route from the private subnet, and iptables masquerade.

Everything durable is in S3, so instances are disposable and resizing is a
stop-change-start.

## Decided against

**Amazon Managed Service for Prometheus.** Retention is configurable to 1095
days, so the 150-day default was not the blocker — cost was. At 1s resolution,
13.1 billion samples a month lands near $570/month in ingest charges alone,
recurring forever, against about $2/month for the same data in S3.

**Amazon Managed Grafana with CloudWatch Logs.** Competitive on price at 15s
resolution, but CloudWatch Logs Insights is a materially worse debugging
experience than Loki with Grafana Explore, and logs are where failures actually
surface.

**Firezone.** Its control plane is hosted-only for production, which fails the
open-source requirement.

**Headscale.** Works, and the Tailscale clients are excellent, but user
management is CLI-first and the web UIs are third-party projects.

**NetBird active-active control plane HA.** Not available open source; it is an
enterprise-license feature. A community Redis-based fork exists, but running a
fork of the component whose failure locks you out of everything is a bad trade.

**A second netbird node, for now.** Cannot provide active-active anyway. Its
real value is relay redundancy and a Postgres replica, which only matters if NAT
traversal fails on the UDM and relay becomes load-bearing. Decide with evidence
after measuring.

**Managed NAT gateway.** Folded into netbird-cp. With S3 on a gateway endpoint,
NAT carries only apt and Docker pulls, so its failure means no updates rather
than an outage.

**Uniform 1s scraping.** vLLM is 5s for the reason above.

## What losing netbird-cp costs

Established WireGuard tunnels are peer-to-peer and survive. Grafana stays
reachable because the observability nodes are direct peers.

What stops: new enrolments, policy changes, re-establishment after a peer
reboots or changes network, relayed connections, and apt updates on the private
subnet.

Recovery is Terraform plus Ansible plus an Elastic IP move, roughly ten minutes,
with no DNS wait.

## Build order

1. Terraform: VPC, subnets, S3 bucket, S3 gateway endpoint, security groups, IAM instance profiles, EC2
2. Ansible role: netbird-cp
3. Enrol a laptop, verify the API, confirm whether Spark peers go direct or relayed
4. Ansible roles: obs-write, obs-read
5. Ansible role: NetBird client and OTel collector onto the Sparks
6. Dashboards

Terraform under `terraform/`, roles under `ansible/roles/`.

## What the build changed

Recorded because each of these differed from the design.

**Spark-to-AWS is relayed, not direct.** NAT traversal fails through the UDM,
so telemetry transits coturn on netbird-cp: 82 ms average against roughly 30 ms
expected direct. The operator has chosen not to change the UDM. This is the
evidence the design said would decide netbird-b, and it argues for adding it:
relay is now load-bearing and the control-plane node sits in the data path.

**No routing peers were created.** Every AWS host runs a client, as designed,
so the VPC needs no route. The lab VLAN route is configured in host_vars but
never reaches the API, so it is not actually advertised. Open item.

**Docker breaks NAT instances.** Docker sets the FORWARD policy to DROP when it
starts, so private-subnet packets die before reaching the masquerade rule. The
NAT rule then shows a zero packet count and looks correct. Rules must go in
DOCKER-USER, which Docker evaluates first and never rewrites.

**thanos-receive binds a port no flag mentions.** It listens on the
remote-write port plus 100 (19391) for remote-write gRPC. Anything else placed
there fails with a bare "address already in use". The compactor now uses 10903.

**Container uids differ per image**: thanos 1001, loki 10001, grafana 472. Data
directories must match or the container crash-loops on permission denied.

**The journald receiver puts the whole entry in the log body**, not in
attributes, so a transform is required both to set `service.name` from the
systemd unit and to reduce the body to the message. Without it every log lands
as `unknown_service` and renders as a JSON blob.

**vLLM renamed its cache metric** to `vllm:kv_cache_usage_perc`, from
`gpu_cache_usage_perc`.

## Open items

- Advertise the lab VLAN route through the NetBird API.
- Disable the `All -> All` default policy so the group policies bind.
- Decide on netbird-b now that relay is confirmed load-bearing.
- PagerDuty. No work now; Grafana Unified Alerting has a native contact point,
  so enabling it later is a routing key rather than a redesign.
