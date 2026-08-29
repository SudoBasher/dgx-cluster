// Cross-node NCCL all-reduce bandwidth, one GPU per rank.
//
// No MPI: rank 0 generates the ncclUniqueId, prints it as hex, and the launcher
// passes that hex to rank 1. Avoids needing an MPI stack or SSH between
// containers.
//
//   rank 0:  allreduce_bw 0 2
//   rank 1:  allreduce_bw 1 2 <hex-from-rank-0>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>
#include <nccl.h>

#define CUDACHECK(x) do { cudaError_t rc_=(x); if(rc_!=cudaSuccess){ \
  fprintf(stderr,"CUDA %s at %d\n",cudaGetErrorString(rc_),__LINE__); exit(1);} } while(0)
#define NCCLCHECK(x) do { ncclResult_t rc_=(x); if(rc_!=ncclSuccess){ \
  fprintf(stderr,"NCCL %s at %d\n",ncclGetErrorString(rc_),__LINE__); exit(1);} } while(0)

static void id_to_hex(const ncclUniqueId* id, char* out){
  const unsigned char* p = (const unsigned char*)id;
  for (size_t i=0;i<sizeof(ncclUniqueId);++i) sprintf(out+2*i, "%02x", p[i]);
  out[2*sizeof(ncclUniqueId)] = 0;
}
static int hex_to_id(const char* hex, ncclUniqueId* id){
  if (strlen(hex) != 2*sizeof(ncclUniqueId)) return -1;
  unsigned char* p = (unsigned char*)id;
  for (size_t i=0;i<sizeof(ncclUniqueId);++i){
    unsigned v; if (sscanf(hex+2*i, "%2x", &v)!=1) return -1; p[i]=(unsigned char)v;
  }
  return 0;
}

int main(int argc, char** argv){
  if (argc < 3){ fprintf(stderr,"usage: %s <rank> <nranks> [hex-id]\n", argv[0]); return 1; }
  int rank = atoi(argv[1]), nranks = atoi(argv[2]);

  ncclUniqueId id;
  if (rank == 0){
    NCCLCHECK(ncclGetUniqueId(&id));
    char hex[2*sizeof(ncclUniqueId)+1]; id_to_hex(&id, hex);
    // The launcher greps for this line, so emit and flush it BEFORE
    // ncclCommInitRank, which blocks until every rank has joined.
    printf("UNIQUEID %s\n", hex); fflush(stdout);
  } else {
    if (argc < 4){ fprintf(stderr,"rank %d needs the hex id\n", rank); return 1; }
    if (hex_to_id(argv[3], &id)){ fprintf(stderr,"bad hex id\n"); return 1; }
  }

  CUDACHECK(cudaSetDevice(0));
  ncclComm_t comm;
  NCCLCHECK(ncclCommInitRank(&comm, nranks, id, rank));

  cudaStream_t stream; CUDACHECK(cudaStreamCreate(&stream));
  if (rank == 0){
    printf("\n%12s %12s %14s %14s\n", "bytes", "time_ms", "algbw_GB/s", "busbw_GB/s");
    fflush(stdout);
  }

  const int WARMUP = 5, ITERS = 20;
  for (size_t bytes = 1L<<12; bytes <= (1L<<26); bytes <<= 1){
    size_t n = bytes / sizeof(float);
    float *sbuf, *rbuf;
    CUDACHECK(cudaMalloc(&sbuf, bytes)); CUDACHECK(cudaMalloc(&rbuf, bytes));
    CUDACHECK(cudaMemset(sbuf, 1, bytes));

    for (int i=0;i<WARMUP;++i)
      NCCLCHECK(ncclAllReduce(sbuf, rbuf, n, ncclFloat, ncclSum, comm, stream));
    CUDACHECK(cudaStreamSynchronize(stream));

    cudaEvent_t ev0, ev1;
    CUDACHECK(cudaEventCreate(&ev0)); CUDACHECK(cudaEventCreate(&ev1));
    CUDACHECK(cudaEventRecord(ev0, stream));
    for (int i=0;i<ITERS;++i)
      NCCLCHECK(ncclAllReduce(sbuf, rbuf, n, ncclFloat, ncclSum, comm, stream));
    CUDACHECK(cudaEventRecord(ev1, stream));
    CUDACHECK(cudaStreamSynchronize(stream));

    float ms; CUDACHECK(cudaEventElapsedTime(&ms, ev0, ev1));
    double t = ms/1e3/ITERS;
    double algbw = bytes/t/1e9;                      // payload / time
    double busbw = algbw * 2.0*(nranks-1)/nranks;    // ring all-reduce wire traffic
    if (rank == 0){
      printf("%12zu %12.3f %14.2f %14.2f\n", bytes, t*1e3, algbw, busbw);
      fflush(stdout);
    }
    CUDACHECK(cudaEventDestroy(ev0)); CUDACHECK(cudaEventDestroy(ev1));
    CUDACHECK(cudaFree(sbuf)); CUDACHECK(cudaFree(rbuf));
  }

  CUDACHECK(cudaStreamDestroy(stream));
  NCCLCHECK(ncclCommDestroy(comm));
  if (rank == 0) printf("\ndone\n");
  return 0;
}
