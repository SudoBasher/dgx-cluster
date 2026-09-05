#!/usr/bin/env bash
# Cross-node NCCL all-reduce: rank 0 on spark1, rank 1 on spark2.
set -u
CFG=/home/user/storage/development/github/sudobasher/dgx-cluster/.ssh/config
SP=/tmp/claude-1000/-home-user-storage-development-github-sudobasher-dgx-cluster/d4a524b3-ff14-4ae5-8027-27a6065e8155/scratchpad
R0=$SP/r0.log; R1=$SP/r1.log
: > "$R0"; : > "$R1"

DEBUG="${NCCL_DEBUG_LEVEL:-WARN}"

# RDMA needs the verbs char devices and unlimited memlock; --network host so the
# ranks see the 192.168.100.x interconnect addresses directly.
# Must be ONE line — embedded newlines survive into the remote shell and are
# interpreted as command separators.
DFLAGS='--rm -i --gpus all --network host --ipc host --shm-size=1g --ulimit memlock=-1 --cap-add IPC_LOCK --device=/dev/infiniband/rdma_cm --device=/dev/infiniband/uverbs0 --device=/dev/infiniband/uverbs1 --device=/dev/infiniband/uverbs2 --device=/dev/infiniband/uverbs3'

HCA="${NCCL_HCA:-rocep1s0f0}"
EXTRA="${EXTRA_ENV:-}"
ENVS="-e NCCL_DEBUG=$DEBUG -e NCCL_IB_HCA=$HCA -e NCCL_IB_GID_INDEX=3 -e NCCL_SOCKET_IFNAME=enp1s0f0np0 -e NCCL_IB_DISABLE=0 $EXTRA"

echo "[launcher] starting rank 0 on spark1 ..."
ssh -F "$CFG" -o BatchMode=yes spark1 \
  "docker run $DFLAGS $ENVS nccl-bench:bin /allreduce_bw 0 2" >>"$R0" 2>&1 &
P0=$!

echo "[launcher] waiting for UNIQUEID ..."
ID=""
for i in $(seq 1 60); do
  ID=$(grep -m1 '^UNIQUEID ' "$R0" 2>/dev/null | awk '{print $2}')
  [ -n "$ID" ] && break
  kill -0 $P0 2>/dev/null || { echo "[launcher] rank 0 died early"; break; }
  sleep 1
done
if [ -z "$ID" ]; then
  echo "[launcher] FAILED to get unique id. rank0 log:"; cat "$R0"; exit 1
fi
echo "[launcher] got id (${#ID} hex chars), starting rank 1 on spark2 ..."

ssh -F "$CFG" -o BatchMode=yes spark2 \
  "docker run $DFLAGS $ENVS nccl-bench:bin /allreduce_bw 1 2 $ID" >>"$R1" 2>&1 &
P1=$!

wait $P0; echo "[launcher] rank0 exit=$?"
wait $P1; echo "[launcher] rank1 exit=$?"

echo
echo "===================== RANK 0 RESULTS ====================="
grep -vE '^UNIQUEID' "$R0"
echo
echo "===================== TRANSPORT =========================="
grep -hiE 'NET/IB|via NET|Channel .* via|Using network|IB Gid|NCCL WARN|Bootstrap' "$R0" "$R1" | sort -u | head -15
