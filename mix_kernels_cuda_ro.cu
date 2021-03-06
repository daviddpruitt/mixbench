/**
 * mix_kernels_cuda_ro.cu: This file is part of the mixbench GPU micro-benchmark suite.
 *
 * Contact: Elias Konstantinidis <ekondis@gmail.com>
 **/

#include <stdio.h>
#include <math_constants.h>
#include <cuda_fp16.h>
#include <stdint.h>
#include <math.h>
#include "lcutil.h"

#ifndef BENCHMARK_FUNCTION
#define BENCHMARK_FUNCTION mad
#define INTEGER_OPS
#define OPS_PER_THREAD 2
#endif

#ifndef OPS_PER_THREAD
#define OPS_PER_THREAD 1
#endif

#ifndef WARMUP_ITERS
#define WARMUP_ITERS 5
#endif

#ifndef BENCH_ITERS
#define BENCH_ITERS 20
#endif

#define ELEMENTS_PER_THREAD (8)
#define FUSION_DEGREE (4)

template<class T>
inline __device__ T conv_int(const int i){ return static_cast<T>(i); }

template<class T>
inline __device__ T mad(const T a, const T b, const T c){ return a*b+c; }

template<class T>
inline __device__ T mul(const T a, const T b, const T c){ return b*c; }

template<class T>
inline __device__ T add(const T a, const T b, const T c){ return b+c; }

template<class T>
inline __device__ T div(const T a, const T b, const T c){ return b/c; }

template<class T>
inline __device__ T exp(const T a, const T b, const T c){ return exp(c); }

template<class T>
inline __device__ T log(const T a, const T b, const T c){ return log(c); }

template<class T>
inline __device__ bool equal(const T a, const T b){ return a==b; }

#if __CUDA_ARCH__ >= 530 && __CUDACC_VER_MAJOR__ >= 9
template<>
inline __device__ half2 conv_int(const int i){ return __half2half2( __int2half_rd(i) ); }
template<>
inline __device__ half2 mad(const half2 a, const half2 b, const half2 c){ return __hfma2(a, b, c)/*__hadd2(__hmul2(a, b), c)*/; }
template<>
inline __device__ half2 mul(const half2 a, const half2 b, const half2 c){ return __hmul2(b, c); }
template<>
inline __device__ half2 add(const half2 a, const half2 b, const half2 c){ return __hadd2(b, c); }
template<>
inline __device__ half2 div(const half2 a, const half2 b, const half2 c){ return __h2div(b, c); }
template<>
inline __device__ half2 exp(const half2 a, const half2 b, const half2 c){ return h2exp(c); }
template<>
inline __device__ half2 log(const half2 a, const half2 b, const half2 c){ return h2log(c); }
template<>
inline __device__ bool equal(const half2 a, const half2 b){ return __hbeq2(a, b); }
#else
// a dummy implementations as a workaround
template<>
inline __device__ half2 conv_int(const int i){ return half2(); }
template<>
inline __device__ half2 mad(const half2 a, const half2 b, const half2 c){ return half2(); }
template<>
inline __device__ half2 mul(const half2 a, const half2 b, const half2 c){ return half2(); }
template<>
inline __device__ half2 add(const half2 a, const half2 b, const half2 c){ return half2(); }
template<>
inline __device__ half2 div(const half2 a, const half2 b, const half2 c){ return half2(); }
template<>
inline __device__ half2 exp(const half2 a, const half2 b, const half2 c){ return half2(); }
template<>
inline __device__ half2 log(const half2 a, const half2 b, const half2 c){ return half2(); }
template<>
inline __device__ bool equal(const half2 a, const half2 b){ return false; }
#endif

template<>
inline __device__ short exp(const short a, const short b, const short c){ return 0; }
template<>
inline __device__ short log(const short a, const short b, const short c){ return 0; }

template<>
inline __device__ int exp(const int a, const int b, const int c){ return 0; }
template<>
inline __device__ int log(const int a, const int b, const int c){ return 0; }

template<>
inline __device__ long exp(const long a, const long b, const long c){ return 0; }
template<>
inline __device__ long log(const long a, const long b, const long c){ return 0; }

template <class T, int blockdim, unsigned int granularity, unsigned int fusion_degree, unsigned int compute_iterations, bool TemperateUnroll>
__global__ void benchmark_func(T seed, T *g_data){
	const unsigned int blockSize = blockdim;
	const int stride = blockSize;
	int idx = blockIdx.x*blockSize*granularity + threadIdx.x;
	const int big_stride = gridDim.x*blockSize*granularity;

	T tmps[granularity];
	for(int k=0; k<fusion_degree; k++){
		#pragma unroll
		for(int j=0; j<granularity; j++){
			// Load elements (memory intensive part)
			tmps[j] = g_data[idx+j*stride+k*big_stride];
			// Perform computations (compute intensive part)
			#pragma unroll TemperateUnroll ? 4 : 128
			for(int i=0; i<compute_iterations; i++){
				tmps[j] = BENCHMARK_FUNCTION(tmps[j], tmps[j], seed);
			}
		}
		// Multiply add reduction
		T sum = conv_int<T>(0);
		#pragma unroll
		for(int j=0; j<granularity; j+=2)
			sum = BENCHMARK_FUNCTION(tmps[j], tmps[j+1], sum);
		// Dummy code
		if( equal(sum, conv_int<T>(-1)) ) // Designed so it never executes
			g_data[idx+k*big_stride] = sum;
	}
}

void initializeEvents(cudaEvent_t *start, cudaEvent_t *stop){
	CUDA_SAFE_CALL( cudaEventCreate(start) );
	CUDA_SAFE_CALL( cudaEventCreate(stop) );
	CUDA_SAFE_CALL( cudaEventRecord(*start, 0) );
}

float finalizeEvents(cudaEvent_t start, cudaEvent_t stop){
	CUDA_SAFE_CALL( cudaGetLastError() );
	CUDA_SAFE_CALL( cudaEventRecord(stop, 0) );
	CUDA_SAFE_CALL( cudaEventSynchronize(stop) );
	float kernel_time;
	CUDA_SAFE_CALL( cudaEventElapsedTime(&kernel_time, start, stop) );
	CUDA_SAFE_CALL( cudaEventDestroy(start) );
	CUDA_SAFE_CALL( cudaEventDestroy(stop) );
	return kernel_time;
}

template<int threads_per_block>
void runbench_warmup(double *cd, long size){
	const long reduced_grid_size = size/(ELEMENTS_PER_THREAD)/128;
	const int BLOCK_SIZE = threads_per_block;
	const int TOTAL_REDUCED_BLOCKS = reduced_grid_size/BLOCK_SIZE;

	dim3 dimBlock(BLOCK_SIZE, 1, 1);
	dim3 dimReducedGrid(TOTAL_REDUCED_BLOCKS, 1, 1);

	for (int iter = 0; iter < WARMUP_ITERS; iter++) {
		benchmark_func< short, BLOCK_SIZE, ELEMENTS_PER_THREAD, FUSION_DEGREE, 0, true ><<< dimReducedGrid, dimBlock >>>((short)1, (short*)cd);
		CUDA_SAFE_CALL( cudaGetLastError() );
		CUDA_SAFE_CALL( cudaThreadSynchronize() );
	}
}

int out_config = 1;

template<unsigned int compute_iterations, int threads_per_block>
void runbench(double *cd, long size, bool doHalfs){
	const long compute_grid_size = size/ELEMENTS_PER_THREAD/FUSION_DEGREE;
	const int BLOCK_SIZE = threads_per_block;
	const int TOTAL_BLOCKS = compute_grid_size/BLOCK_SIZE;
	const long long computations = (ELEMENTS_PER_THREAD*(long long)compute_grid_size+(OPS_PER_THREAD*ELEMENTS_PER_THREAD*compute_iterations)*(long long)compute_grid_size)*FUSION_DEGREE;
	const long long memoryoperations = size;
	float kernel_time_mad_sp = 0, kernel_time_mad_dp = 0, kernel_time_mad_hp = 0;
#ifdef INTEGER_OPS // to avoid unused variable warnings
 	float kernel_time_mad_int = 0;
#endif

	dim3 dimBlock(BLOCK_SIZE, 1, 1);
	dim3 dimGrid(TOTAL_BLOCKS, 1, 1);
	cudaEvent_t start, stop;

	for (int iter = 0; iter < BENCH_ITERS; iter++) {
		initializeEvents(&start, &stop);
		benchmark_func< float, BLOCK_SIZE, ELEMENTS_PER_THREAD, FUSION_DEGREE, compute_iterations, false ><<< dimGrid, dimBlock >>>(1.0f, (float*)cd);
		kernel_time_mad_sp += finalizeEvents(start, stop);
	}
	kernel_time_mad_sp = kernel_time_mad_sp / BENCH_ITERS;

	for (int iter = 0; iter < BENCH_ITERS; iter++) {
		initializeEvents(&start, &stop);
		benchmark_func< double, BLOCK_SIZE, ELEMENTS_PER_THREAD, FUSION_DEGREE, compute_iterations, false ><<< dimGrid, dimBlock >>>(1.0, cd);
		kernel_time_mad_dp += finalizeEvents(start, stop);
	}
	kernel_time_mad_dp = kernel_time_mad_dp / BENCH_ITERS;

	kernel_time_mad_hp = 0.f;
	if( doHalfs ){
		for (int iter = 0; iter < BENCH_ITERS; iter++) {
			initializeEvents(&start, &stop);
			half2 h_ones;
			*((int32_t*)&h_ones) = 15360 + (15360 << 16); // 1.0 as half
			benchmark_func< half2, BLOCK_SIZE, ELEMENTS_PER_THREAD, FUSION_DEGREE, compute_iterations, false ><<< dimGrid, dimBlock >>>(h_ones, (half2*)cd);
			kernel_time_mad_hp += finalizeEvents(start, stop);
		}
		kernel_time_mad_hp = kernel_time_mad_hp / BENCH_ITERS;
	}

#ifdef INTEGER_OPS
	for (int iter = 0; iter < BENCH_ITERS; iter++) {
		initializeEvents(&start, &stop);
		benchmark_func< int, BLOCK_SIZE, ELEMENTS_PER_THREAD, FUSION_DEGREE, compute_iterations, true ><<< dimGrid, dimBlock >>>(1, (int*)cd);
		kernel_time_mad_int += finalizeEvents(start, stop);
	}
	kernel_time_mad_int = kernel_time_mad_int / BENCH_ITERS;
#endif

#ifdef INTEGER_OPS
	printf("         %4d,         %4d   %8.3f,%8.2f,%8.2f,%7.2f,   %8.3f,%8.2f,%8.2f,%7.2f,   %8.3f,%8.2f,%8.2f,%7.2f,  %8.3f,%8.2f,%8.2f,%7.2f\n",
		compute_iterations,
		BLOCK_SIZE,
		((double)computations)/((double)memoryoperations*sizeof(float)),
		kernel_time_mad_sp,
		((double)computations)/kernel_time_mad_sp*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(float))/kernel_time_mad_sp*1000./(1000.*1000.*1000.),
		((double)computations)/((double)memoryoperations*sizeof(double)),
		kernel_time_mad_dp,
		((double)computations)/kernel_time_mad_dp*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(double))/kernel_time_mad_dp*1000./(1000.*1000.*1000.),
		((double)2*computations)/((double)memoryoperations*sizeof(half2)),
		kernel_time_mad_hp,
		((double)2*computations)/kernel_time_mad_hp*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(half2))/kernel_time_mad_hp*1000./(1000.*1000.*1000.),
		((double)computations)/((double)memoryoperations*sizeof(int)),
		kernel_time_mad_int,
		((double)computations)/kernel_time_mad_int*1000./(double)(1000*1000*1000),
		((double)memoryoperations*sizeof(int))/kernel_time_mad_int*1000./(1000.*1000.*1000.) );
#else
		printf("         %4d,         %4d   %8.3f,%8.2f,%8.2f,%7.2f,   %8.3f,%8.2f,%8.2f,%7.2f,   %8.3f,%8.2f,%8.2f,%7.2f\n",
			compute_iterations,
			BLOCK_SIZE,
			((double)computations)/((double)memoryoperations*sizeof(float)),
			kernel_time_mad_sp,
			((double)computations)/kernel_time_mad_sp*1000./(double)(1000*1000*1000),
			((double)memoryoperations*sizeof(float))/kernel_time_mad_sp*1000./(1000.*1000.*1000.),
			((double)computations)/((double)memoryoperations*sizeof(double)),
			kernel_time_mad_dp,
			((double)computations)/kernel_time_mad_dp*1000./(double)(1000*1000*1000),
			((double)memoryoperations*sizeof(double))/kernel_time_mad_dp*1000./(1000.*1000.*1000.),
			((double)2*computations)/((double)memoryoperations*sizeof(half2)),
			kernel_time_mad_hp,
			((double)2*computations)/kernel_time_mad_hp*1000./(double)(1000*1000*1000),
			((double)memoryoperations*sizeof(half2))/kernel_time_mad_hp*1000./(1000.*1000.*1000.) );
#endif
}

extern "C" void mixbenchGPU(double *c, long size){
	const char *benchtype = "compute BENCHMARK_FUNCTION with global memory (block strided)";

	printf("Trade-off type:       %s\n", benchtype);
	printf("Elements per thread:  %d\n", ELEMENTS_PER_THREAD);
	printf("Thread fusion degree: %d\n", FUSION_DEGREE);
	double *cd;
	bool doHalfs = IsFP16Supported();
	if( !doHalfs )
		printf("Warning:              Half precision computations are not supported\n");

	CUDA_SAFE_CALL( cudaMalloc((void**)&cd, size*sizeof(double)) );

	// Copy data to device memory
	CUDA_SAFE_CALL( cudaMemset(cd, 0, size*sizeof(double)) );  // initialize to zeros

	// Synchronize in order to wait for memory operations to finish
	CUDA_SAFE_CALL( cudaThreadSynchronize() );

	printf("\n----- Varying operational intensity -----\n");
#ifdef INTEGER_OPS
	printf("----------------------------------------------------------------------------- CSV data -----------------------------------------------------------------------------\n");
	printf("Experiment ID,              ,Single Precision ops,,,,              Double precision ops,,,,              Half precision ops,,,,                Integer operations,,, \n");
	printf("Compute iters, Threads/block,Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Iops/byte, ex.time,   GIOPS, GB/sec\n");
#else
	printf("----------------------------------------------------------------------------- CSV data ------------------------------------------\n");
	printf("Experiment ID,              ,Single Precision ops,,,,              Double precision ops,,,,              Half precision ops,,,,                \n");
	printf("Compute iters, Threads/block, Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, \n");
#endif
	runbench_warmup<256>(cd, size);

	runbench<  0, 256>(cd, size, doHalfs);
	runbench<  1, 256>(cd, size, doHalfs);
	runbench<  2, 256>(cd, size, doHalfs);
	runbench<  3, 256>(cd, size, doHalfs);
	runbench<  4, 256>(cd, size, doHalfs);
	runbench<  5, 256>(cd, size, doHalfs);
	runbench<  6, 256>(cd, size, doHalfs);
	runbench<  7, 256>(cd, size, doHalfs);
	runbench<  8, 256>(cd, size, doHalfs);
	runbench<  9, 256>(cd, size, doHalfs);
	runbench< 10, 256>(cd, size, doHalfs);
	runbench< 11, 256>(cd, size, doHalfs);
	runbench< 12, 256>(cd, size, doHalfs);
	runbench< 13, 256>(cd, size, doHalfs);
	runbench< 14, 256>(cd, size, doHalfs);
	runbench< 15, 256>(cd, size, doHalfs);
	runbench< 16, 256>(cd, size, doHalfs);
	runbench< 17, 256>(cd, size, doHalfs);
	runbench< 18, 256>(cd, size, doHalfs);
	runbench< 20, 256>(cd, size, doHalfs);
	runbench< 22, 256>(cd, size, doHalfs);
	runbench< 24, 256>(cd, size, doHalfs);
	runbench< 28, 256>(cd, size, doHalfs);
	runbench< 32, 256>(cd, size, doHalfs);
	runbench< 40, 256>(cd, size, doHalfs);
	runbench< 48, 256>(cd, size, doHalfs);
	runbench< 56, 256>(cd, size, doHalfs);
	runbench< 64, 256>(cd, size, doHalfs);
	runbench< 80, 256>(cd, size, doHalfs);
	runbench< 96, 256>(cd, size, doHalfs);
	runbench<128, 256>(cd, size, doHalfs);
	runbench<192, 256>(cd, size, doHalfs);
	runbench<256, 256>(cd, size, doHalfs);

	printf("--------------------------------------------------------------------------------------------------------------------------------------------------------------------\n");

	printf("\n----- Varying number of threads -----\n");
#ifdef INTEGER_OPS
	printf("----------------------------------------------------------------------------- CSV data -----------------------------------------------------------------------------\n");
	printf("Experiment ID,              ,Single Precision ops,,,,              Double precision ops,,,,              Half precision ops,,,,                Integer operations,,, \n");
	printf("Compute iters, Threads/block,Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Iops/byte, ex.time,   GIOPS, GB/sec\n");
#else
	printf("----------------------------------------------------------------------------- CSV data ------------------------------------------\n");
	printf("Experiment ID,              ,Single Precision ops,,,,              Double precision ops,,,,              Half precision ops,,,,                \n");
	printf("Compute iters, Threads/block, Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, Flops/byte, ex.time,  GFLOPS, GB/sec, \n");
#endif
	runbench_warmup<32>(cd, size);

	runbench<256,  1>(cd, size, doHalfs);
	runbench<256,  2>(cd, size, doHalfs);
	runbench<256,  3>(cd, size, doHalfs);
	runbench<256,  4>(cd, size, doHalfs);
	runbench<256,  5>(cd, size, doHalfs);
	runbench<256,  6>(cd, size, doHalfs);
	runbench<256,  7>(cd, size, doHalfs);
	runbench<256,  8>(cd, size, doHalfs);
	runbench<256,  9>(cd, size, doHalfs);
	runbench<256, 10>(cd, size, doHalfs);
	runbench<256, 11>(cd, size, doHalfs);
	runbench<256, 12>(cd, size, doHalfs);
	runbench<256, 13>(cd, size, doHalfs);
	runbench<256, 14>(cd, size, doHalfs);
	runbench<256, 15>(cd, size, doHalfs);
	runbench<256, 16>(cd, size, doHalfs);
	runbench<256, 17>(cd, size, doHalfs);
	runbench<256, 18>(cd, size, doHalfs);
	runbench<256, 19>(cd, size, doHalfs);
	runbench<256, 20>(cd, size, doHalfs);
	runbench<256, 21>(cd, size, doHalfs);
	runbench<256, 22>(cd, size, doHalfs);
	runbench<256, 23>(cd, size, doHalfs);
	runbench<256, 24>(cd, size, doHalfs);
	runbench<256, 25>(cd, size, doHalfs);
	runbench<256, 26>(cd, size, doHalfs);
	runbench<256, 27>(cd, size, doHalfs);
	runbench<256, 28>(cd, size, doHalfs);
	runbench<256, 29>(cd, size, doHalfs);
	runbench<256, 30>(cd, size, doHalfs);
	runbench<256, 31>(cd, size, doHalfs);
	runbench<256, 32>(cd, size, doHalfs);

	printf("--------------------------------------------------------------------------------------------------------------------------------------------------------------------\n");

	// Copy results back to host memory
	CUDA_SAFE_CALL( cudaMemcpy(c, cd, size*sizeof(double), cudaMemcpyDeviceToHost) );

	CUDA_SAFE_CALL( cudaFree(cd) );

	CUDA_SAFE_CALL( cudaDeviceReset() );
}
