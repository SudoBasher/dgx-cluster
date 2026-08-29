# Next steps

Open work on the cluster, roughly in priority order. Current state is in
`FINDINGS.md`; procedures are in `RUNBOOK.md` and `ansible/README.md`.

## 1. Add `ms_api_key` — deferred, do this later

The vLLM endpoints are currently **unauthenticated and bound to 0.0.0.0**.
Anyone on the LAN can send requests to either GPU. This was left out of the
initial deployment deliberately to keep the first run simple, and needs adding.

The work: a `ms_api_key` variable in `roles/model_server/defaults/main.yml`,
passed through to `--api-key` in the systemd unit template, with the value kept
out of git via ansible-vault or a file outside the repo. Clients then send
`Authorization: Bearer <key>`, which AnythingLLM's Generic OpenAI provider
already supports in its API key field.

Worth pairing with a decision on whether the endpoints should be reachable from
the whole LAN at all, or bound to a specific interface.

## 2. Disable thinking by default

Qwen3.8 is a reasoning model and roughly 90% of generated tokens are chain of
thought the user never sees. "Name three primary colours" spends 54 reasoning
tokens on an 8-token answer, about seven seconds. This is more noticeable in
practice than the raw 4-8 tok/s.

Options: a per-request `chat_template_kwargs: {"enable_thinking": false}`,
which requires client support, or a server-side default in the role so short
queries return promptly and reasoning is opted into rather than out of.

## 3. Commit the repository

Nothing is committed yet. The working tree holds the runbook, findings,
monitoring guide, benchmarks and the full Ansible deployment. `.gitignore`
excludes the private key; confirm with `git status --short --untracked-files=all`
before the first commit.

## 4. Benchmark throughput properly

Measured samples ranged 4.3-8.4 tok/s, which is too wide to plan around. The
spread is some mix of warmth, generation length and sampling noise, and has not
been separated. A short sweep over fixed prompt and output lengths, warm, on
both nodes, would give a number worth quoting. Concurrency behaviour is also
untested: vLLM batches continuously, so aggregate throughput under several
simultaneous requests should be well above the single-stream figure.

## 5. Repoint spark2 at a second model

The stated plan. `ansible/host_vars/spark2.yml` is the only file that needs to
change; see `ansible/README.md`. Candidates evaluated against this hardware are
in `FINDINGS.md`. Note that `ms_weights_peer` can stay set: it falls back to a
Hugging Face download automatically once spark1 no longer has the model.

Once the nodes serve different models, treat them as separate endpoints rather
than replicas.

## 6. Connect AnythingLLM

Generic OpenAI provider, base URL `http://spark-a01a.local:8000/v1`, model
`qwen3.8-27b`. Set the token context window well below the 262144 the server
advertises, or it will build prompts large enough to make prefill feel like a
hang. Run it on the workstation, not on a Spark.

## 7. Re-test GPUDirect RDMA after any driver update

NCCL cross-node collectives are capped at 3.0 GB/s, about 21% of the wire,
because `nvidia-peermem.ko` will not insert on GB10 and NCCL falls back to
staging through host memory. If a future driver makes `modprobe nvidia_peermem`
succeed, re-run `RUNBOOK.md` section 9b. A working GDR path would raise the
ceiling toward 14 GB/s and make tensor parallelism across nodes viable, which
would change the serving topology advice.

## Decided against

Recorded so these do not get relitigated.

**A second interconnect cable.** Per token, memory moves 10^4 to 10^6 times more
bytes than the network. The link is also already software-limited at 21% of the
wire by the missing GDR path, so widening it addresses the wrong bottleneck.
The second QSFP cage is empty and a cable would attach, but measure with a
borrowed one before buying.

**Tensor parallelism across nodes.** Roughly 27 GB of wire traffic for an
8k-token prefill, about 9 seconds at 3.0 GB/s, against 45 ms for pipeline
parallel. Never raise `ms_tensor_parallel_size` above 1.

**A load balancer in front of both nodes.** Correct only while both run the same
model, and the plan is for them to diverge. AnythingLLM workspaces can each
target a different endpoint, which fits better.

**bf16 weights.** Capacity-limits the cluster to about 110B parameters and
doubles memory traffic on hardware where decode is bandwidth-bound. FP8 is the
quality-preserving default here.
