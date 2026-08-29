// GPU memory bandwidth on GB10 unified LPDDR5X.
// BabelStream-style kernels: the READ figure is the closest analogue to
// streaming model weights during LLM decode.
#include <cstdio>
#include <cuda_runtime.h>

// NB: the internal variable must have an unlikely name — a plain `e` shadows
// caller variables passed by address (e.g. cudaEventCreate(&e)) and produces a
// baffling "no matching overload" error.
#define CHECK(x) do { cudaError_t err_##__LINE__ = (x); if(err_##__LINE__ != cudaSuccess){ \
  printf("CUDA error %s at line %d\n", cudaGetErrorString(err_##__LINE__), __LINE__); return 1; } } while(0)

typedef double T;
__global__ void k_copy (T*  c, const T* a, size_t n){ size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x; if(i<n) c[i]=a[i]; }
__global__ void k_mul  (T*  b, const T* c, size_t n){ size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x; if(i<n) b[i]=3.0*c[i]; }
__global__ void k_triad(T*  a, const T* b, const T* c, size_t n){ size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x; if(i<n) a[i]=b[i]+3.0*c[i]; }

// Pure read: strided grid loop, result forced to memory so nothing is elided.
__global__ void k_read(const T* a, size_t n, T* out){
  size_t i = blockIdx.x*(size_t)blockDim.x + threadIdx.x;
  size_t stride = (size_t)gridDim.x*blockDim.x;
  T s = 0;
  for(; i<n; i+=stride) s += a[i];
  if (s == 12345.6789) out[0] = s;   // never true; prevents dead-code removal
}

int main(){
  cudaDeviceProp p; CHECK(cudaGetDeviceProperties(&p,0));
  printf("device            : %s\n", p.name);
  printf("SMs               : %d\n", p.multiProcessorCount);
  printf("bus width         : %d bit\n", p.memoryBusWidth);
  // cudaDeviceProp::memoryClockRate was removed in CUDA 13; query the attribute.
  int mclk_khz = 0;
  if (cudaDeviceGetAttribute(&mclk_khz, cudaDevAttrMemoryClockRate, 0) == cudaSuccess && mclk_khz > 0)
    // The attribute already reports the DATA RATE (MT/s) for LPDDR5X, so do NOT
    // apply an extra x2 for DDR — that double-counts and reports 546 instead of 273.
    printf("spec bandwidth    : %.1f GB/s (%d MT/s x %d bit)\n",
           mclk_khz*1e3*(p.memoryBusWidth/8.0)/1e9, mclk_khz/1000, p.memoryBusWidth);

  const size_t N = (size_t)1<<28;          // 268M doubles = 2 GiB per array
  const size_t bytes = N*sizeof(T);
  printf("array size        : %.2f GiB each (3 arrays)\n\n", bytes/1073741824.0);

  T *a,*b,*c,*out;
  CHECK(cudaMalloc(&a,bytes)); CHECK(cudaMalloc(&b,bytes));
  CHECK(cudaMalloc(&c,bytes)); CHECK(cudaMalloc(&out,sizeof(T)));
  CHECK(cudaMemset(a,1,bytes)); CHECK(cudaMemset(b,2,bytes)); CHECK(cudaMemset(c,0,bytes));

  int threads=256; size_t blocks=(N+threads-1)/threads;
  size_t rblocks = p.multiProcessorCount*32;   // grid-stride loop for the read kernel

  cudaEvent_t s,e; CHECK(cudaEventCreate(&s)); CHECK(cudaEventCreate(&e));
  float ms; const int NT=10;
  double best_copy=1e30,best_mul=1e30,best_triad=1e30,best_read=1e30;

  for(int it=0; it<NT; ++it){
    CHECK(cudaEventRecord(s));  k_copy<<<blocks,threads>>>(c,a,N);
    CHECK(cudaEventRecord(e));  CHECK(cudaEventSynchronize(e));
    CHECK(cudaEventElapsedTime(&ms,s,e)); if(ms<best_copy) best_copy=ms;

    CHECK(cudaEventRecord(s));  k_mul<<<blocks,threads>>>(b,c,N);
    CHECK(cudaEventRecord(e));  CHECK(cudaEventSynchronize(e));
    CHECK(cudaEventElapsedTime(&ms,s,e)); if(ms<best_mul) best_mul=ms;

    CHECK(cudaEventRecord(s));  k_triad<<<blocks,threads>>>(a,b,c,N);
    CHECK(cudaEventRecord(e));  CHECK(cudaEventSynchronize(e));
    CHECK(cudaEventElapsedTime(&ms,s,e)); if(ms<best_triad) best_triad=ms;

    CHECK(cudaEventRecord(s));  k_read<<<rblocks,threads>>>(a,N,out);
    CHECK(cudaEventRecord(e));  CHECK(cudaEventSynchronize(e));
    CHECK(cudaEventElapsedTime(&ms,s,e)); if(ms<best_read) best_read=ms;
  }
  CHECK(cudaGetLastError());

  printf("COPY  (r+w)       : %7.1f GB/s\n", 2.0*bytes/(best_copy /1e3)/1e9);
  printf("MUL   (r+w)       : %7.1f GB/s\n", 2.0*bytes/(best_mul  /1e3)/1e9);
  printf("TRIAD (2r+w)      : %7.1f GB/s\n", 3.0*bytes/(best_triad/1e3)/1e9);
  printf("READ  (r)         : %7.1f GB/s   <- LLM weight-streaming analogue\n",
         1.0*bytes/(best_read /1e3)/1e9);
  return 0;
}
