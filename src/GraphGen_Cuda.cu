#include <string>
#include <algorithm>
#include <math.h>
#include <stdio.h>
#include <vector>
#include <cub/cub.cuh>
#include <iostream>
#include <cstring>
#include <fstream>
#include <cstdlib>

#include <curand.h>
#include <curand_kernel.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>
#include "GraphGen_Cuda.h"
#include "internal_config.hpp"
#include "Square.hpp"
#include "Edge.hpp"
#include "utils.hpp"
#include "exclusiveScan.cu_inl"

#define cudacall(call) \
{ \
    cudaError_t err = (call);                                                                                               \
    if(cudaSuccess != err)                                                                                                  \
    {                                                                                                                       \
        fprintf(stderr,"CUDA Error:\nFile = %s\nLine = %d\nReason = %s\n", __FILE__, __LINE__, cudaGetErrorString(err));    \
        cudaDeviceReset();                                                                                                  \
        exit(EXIT_FAILURE);                                                                                                 \
    }                                                                                                                       \
} \

struct cudaSquare {
	uint X_start, X_end, Y_start, Y_end;
	uint nEdgeToGenerate, level, recIndex_horizontal, recIndex_vertical;
	uint thisEdgeToGenerate;
};

struct GlobalConstants {

    uint cudaDeviceNumEdges, cudaDeviceNumVertices;
    double* cudaDeviceProbs;
    int* cudaDeviceOutput;
    uint* cudaDeviceCompressedOutput;
    cudaSquare* cudaSquares;
    curandState_t* cudaThreadStates;
    int nSquares;
    bool directedGraph, allowEdgeToSelf, sorted;
};

__device__ inline int updiv(int n, int d) {
    return (n+d-1)/d;
}

__constant__ GlobalConstants cuConstGraphParams;

/* CUDA's random number library uses curandState_t to keep track of the seed value
   we will store a random state for every thread  */

/* this GPU kernel function is used to initialize the random states */
__global__ void init(unsigned int seed) {

  /* we have to initialize the state */
    // printf("seed %d\n", seed);
  curandState_t* states = cuConstGraphParams.cudaThreadStates;
  curand_init(seed, /* the seed can be the same for each core, here we pass the time in from the CPU */
              blockIdx.x*blockDim.x+threadIdx.x, /* the sequence number should be different for each core (unless you want all
                             cores to get the same sequence of numbers for some reason - use thread id! */
              0, /* the offset is how much extra we advance in the sequence for each call, can be 0 */
              &states[blockIdx.x*blockDim.x+threadIdx.x]);
  // const double RndProb = curand_uniform(states + blockIdx.x);
  // printf("RANDOM RANDOM %lf\n", RndProb);
}

__device__ __inline__ int2
get_Edge_indices(curandState_t* states,  uint offX, uint rngX, uint offY, uint rngY, double A[],double B[],double C[],double D[]) {
    uint x_offset = offX, y_offset = offY;
    uint rangeX = rngX, rangeY = rngY;
    uint depth =0;
    double sumA, sumAB, sumABC, sumAC;
    int idx = blockDim.x*blockIdx.x+threadIdx.x;
    curandState_t localState = states[idx];
    // printf("reached here\n");
    while (rangeX > 1 || rangeY > 1) {
        // printf("depth is %u\n",depth );
        // printf("%d %d\n",rngX,rngY );
        sumA = A[depth];
        sumAB = sumA + B[depth];
        sumAC = sumA + C[depth];
        sumABC = sumAB + C[depth];
        

        const double RndProb = curand_uniform(&localState);
        // printf("%d %d RANDOM %lf\n", blockIdx.x , threadIdx.x,RndProb );
        if (rangeX>1 && rangeY>1) {
          if (RndProb < sumA) { rangeX/=2; rangeY/=2; }
          else if (RndProb < sumAB) { x_offset+=rangeX/2;  rangeX-=rangeX/2;  rangeY/=2; }
          else if (RndProb < sumABC) { y_offset+=rangeY/2;  rangeX/=2;  rangeY-=rangeY/2; }
          else { x_offset+=rangeX/2;  y_offset+=rangeY/2;  rangeX-=rangeX/2;  rangeY-=rangeY/2; }
        } else
        if (rangeX>1) { // row vector
          if (RndProb < sumAC) { rangeX/=2; rangeY/=2; }
          else { x_offset+=rangeX/2;  rangeX-=rangeX/2;  rangeY/=2; }
        } else
        if (rangeY>1) { // column vector
          if (RndProb < sumAB) { rangeX/=2; rangeY/=2; }
          else { y_offset+=rangeY/2;  rangeX/=2;  rangeY-=rangeY/2; }
        } else{
            //printf("Hello from block %d, thread %d\n", blockIdx.x, threadIdx.x);
        }
        depth++;
    }
    states[idx] = localState;
    int2 e;
    //printf("Edge %d %d\n", (int)x_offset, (int)y_offset);

    e.x = x_offset;
    e.y = y_offset;
    // printf("returning here\n");

    return e;
}
__global__ void KernelGenerateEdges() {
    // std::uniform_int_distribution<>& dis, std::mt19937_64& gen,
    // std::vector<uint>& duplicate_indices
    //printf("BlockIdx %d ThreadIdx %d\n",blockIdx.x, threadIdx.x);
    curandState_t* states = cuConstGraphParams.cudaThreadStates;
    bool directedGraph = cuConstGraphParams.directedGraph;
    bool allowEdgeToSelf = cuConstGraphParams.allowEdgeToSelf;
    bool sorted = cuConstGraphParams.sorted;
    int blockIndex = blockIdx.x;
    int offset = blockIndex;
    int threadIndex = threadIdx.x;
    if (blockIndex < cuConstGraphParams.nSquares) {
        cudaSquare squ = (cudaSquare)cuConstGraphParams.cudaSquares[blockIndex];
        __shared__ uint offX;  
        __shared__ uint offY;  
        __shared__ uint rngX;  
        __shared__ uint rngY;  
        
        __shared__ uint nEdgesToGen;
        if (threadIndex==0)
        {
            offX = (uint)squ.X_start;
            offY = (uint)squ.Y_start;
            rngX = (uint)squ.X_end-offX;
            rngY = (uint)squ.Y_end-offY;
            nEdgesToGen = (uint)squ.nEdgeToGenerate;
            // printf("Found Square x: [%u,%u] y: [%u, %u] %u\n", offX,  offX+rngX,offY,offY+rngY, nEdgesToGen);
        }   
        __shared__ double A[MAX_DEPTH];
        __shared__ double B[MAX_DEPTH];
        __shared__ double C[MAX_DEPTH];
        __shared__ double D[MAX_DEPTH];

        if (threadIndex==0)
        {
            for (int i = 0; i < MAX_DEPTH; ++i)
            {
                A[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)]);
                B[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i) + 1]);
                C[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)+ 2]);
                D[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)+ 3]);
            }
            // printf("ENDED probs\n");
        }
        __syncthreads();

        auto applyCondition = directedGraph || ( offX < offY); // true: if the graph is directed or in case it is undirected, the square belongs to the lower triangle of adjacency matrix. false: the diagonal passes the rectangle and the graph is undirected.


        unsigned maxIter = updiv(nEdgesToGen, blockDim.x);

        for (unsigned i = 0; i < maxIter; ++i)
        {
           int edgeIdx = i * blockDim.x + threadIndex;
           int2 e;
           if (edgeIdx < nEdgesToGen )
           {

               while(true) {
                   e = get_Edge_indices(states, offX, rngX, offY, rngY, A, B, C, D );
                   uint h_idx = e.x;
                   uint v_idx = e.y;
                   if( (!applyCondition && h_idx > v_idx) || (!allowEdgeToSelf && h_idx == v_idx ) ) {// Short-circuit if it doesn't pass the test.
                       printf("EdgeID %d fail1\n", edgeIdx );
                       continue;
                   } else if (h_idx< offX || h_idx>= offX+rngX || v_idx < offY || v_idx >= offY+rngY ){
                       printf("EdgeID %d recompute src %d dst %d tl %d tr %d bl %d br %d \n", edgeIdx, h_idx, v_idx, offX, offY, offX+rngX, offY+rngY);
                       continue;
                   } else {
                       break;
                   }
               }
               // printf("Edges Calculated %d \t %d\n", e.x,e.y);
               cuConstGraphParams.cudaDeviceOutput[2*( squ.thisEdgeToGenerate + edgeIdx)] = e.x;
               cuConstGraphParams.cudaDeviceOutput[2*( squ.thisEdgeToGenerate + edgeIdx)+1] = e.y;

           }
           __syncthreads();
        }
        __syncthreads();
    }

}


__global__ void KernelGenerateEdgesCompressed() {
    // std::uniform_int_distribution<>& dis, std::mt19937_64& gen,
    // std::vector<uint>& duplicate_indices
    //printf("BlockIdx %d ThreadIdx %d\n",blockIdx.x, threadIdx.x);
    curandState_t* states = cuConstGraphParams.cudaThreadStates;
    bool directedGraph = cuConstGraphParams.directedGraph;
    bool allowEdgeToSelf = cuConstGraphParams.allowEdgeToSelf;
    bool sorted = cuConstGraphParams.sorted;
    int blockIndex = blockIdx.x;
    // int offset = blockIndex;
    int threadIndex = threadIdx.x;
    if (blockIndex < cuConstGraphParams.nSquares) {
        cudaSquare squ = (cudaSquare)cuConstGraphParams.cudaSquares[blockIndex];
        __shared__ uint offX;  
        __shared__ uint offY;  
        __shared__ uint rngX;  
        __shared__ uint rngY;  
        __shared__ uint offset;
        __shared__ uint nEdgesToGen;
        if (threadIndex==0)
        {
            offX = (uint)squ.X_start;
            offY = (uint)squ.Y_start;
            rngX = (uint)squ.X_end-offX;
            rngY = (uint)squ.Y_end-offY;
            nEdgesToGen = (uint)squ.nEdgeToGenerate;
            offset = (uint)squ.thisEdgeToGenerate;

            // printf("Found Square x: [%u,%u] y: [%u, %u] %u %u\n", offX,  offX+rngX,offY,offY+rngY, nEdgesToGen, offset);
        }   
        __shared__ double A[MAX_DEPTH];
        __shared__ double B[MAX_DEPTH];
        __shared__ double C[MAX_DEPTH];
        __shared__ double D[MAX_DEPTH];
        __shared__ uint shared_edges[MAX_NUM_EDGES_PER_BLOCK];

        if (threadIndex==0)
        {
            for (int i = 0; i < MAX_DEPTH; ++i)
            {
                A[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)]);
                B[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i) + 1]);
                C[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)+ 2]);
                D[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)+ 3]);
            }
            // printf("ENDED probs\n");
        }
        __syncthreads();

        auto applyCondition = directedGraph || ( offX < offY); // true: if the graph is directed or in case it is undirected, the square belongs to the lower triangle of adjacency matrix. false: the diagonal passes the rectangle and the graph is undirected.


        unsigned maxIter = updiv(nEdgesToGen, blockDim.x);

        for (unsigned i = 0; i < maxIter; ++i)
        {
           int edgeIdx = i * blockDim.x + threadIndex;
           int2 e;
           if (edgeIdx < nEdgesToGen )
           {

               while(true) {
                   e = get_Edge_indices(states, offX, rngX, offY, rngY, A, B, C, D );
                   uint h_idx = e.x;
                   uint v_idx = e.y;
                   if( (!applyCondition && h_idx > v_idx) || (!allowEdgeToSelf && h_idx == v_idx ) ) {// Short-circuit if it doesn't pass the test.
                       printf("EdgeID %d fail1\n", edgeIdx );
                       continue;
                   } else if (h_idx< offX || h_idx>= offX+rngX || v_idx < offY || v_idx >= offY+rngY ){
                       printf("EdgeID %d recompute src %d dst %d tl %d tr %d bl %d br %d \n", edgeIdx, h_idx, v_idx, offX, offY, offX+rngX, offY+rngY);
                       continue;
                   } else {
                       break;
                   }
               }
               // printf("Edges Calculated %d \t %d %u Square %d %d \n", e.x,e.y, (e.x-offX)*rngY+(e.y - offY), blockIndex, offset);
               shared_edges[edgeIdx] = (e.x-offX)*rngY+(e.y - offY);
               cuConstGraphParams.cudaDeviceCompressedOutput[( offset + edgeIdx)] = shared_edges[edgeIdx];
               // cuConstGraphParams.cudaDeviceOutput[2*( squ.thisEdgeToGenerate + edgeIdx)+1] = e.y;

           }
           __syncthreads();
        }
        __syncthreads();
    }

}

////////////////////////////////////////////////////////////////////////////////////////
/* this GPU kernel function is used to initialize the random states */
__global__ void initSorted(unsigned int seed) {

  /* we have to initialize the state */
    // printf("seed %d\n", seed);
  curandState_t* states = cuConstGraphParams.cudaThreadStates;
  curand_init(seed, /* the seed can be the same for each core, here we pass the time in from the CPU */
              blockIdx.x*blockDim.x+threadIdx.x, /* the sequence number should be different for each core (unless you want all
                             cores to get the same sequence of numbers for some reason - use thread id! */
              0, /* the offset is how much extra we advance in the sequence for each call, can be 0 */
              &states[blockIdx.x*blockDim.x+threadIdx.x]);
  // const double RndProb = curand_uniform(states + blockIdx.x);
  // printf("RANDOM RANDOM %lf\n", RndProb);
}

__device__ __inline__ int2
get_Edge_indices_PKSG(curandState_t* states, uint offX, uint rngX,uint offY, uint rngY, uint u, double A[],double B[],double C[],double D[]) {
    uint z=u, v=0, s=0;
    int idx = blockDim.x*blockIdx.x+threadIdx.x;
    // printf("reached here\n");
    curandState_t localState = states[idx];
    int k = ceil(log2((double)rngX));

    for (int depth = 0; depth<k-1; ++depth)
    {

        // printf("depth %d\n",depth );
      double sumAB = A[depth] +B[depth];
      double a = A[depth]/sumAB;
      double b = B[depth]/sumAB;
      double c = C[depth]/(1-sumAB);
      double d = D[depth]/(1-sumAB);
      uint l = z%2;
      const double RndProb = curand_uniform(&localState);
      if (l==0) {
        s=1;
        if (RndProb<a) {
          s=0;
        }
      } else {
        s=1;
        if (RndProb<c) {
          s=0;   
        }
      }
      v= 2*v+s;
      z= z/2;
    }
    
    int2 e;
    e.x = u;
    e.y = v+offY;
    return e;
}

__global__ void KernelGenerateEdgesPSKG() {
    curandState_t* states = cuConstGraphParams.cudaThreadStates;
    bool directedGraph = cuConstGraphParams.directedGraph;
    bool allowEdgeToSelf = cuConstGraphParams.allowEdgeToSelf;
    bool sorted = cuConstGraphParams.sorted;
    int blockIndex = blockIdx.x;
    int threadIndex = threadIdx.x;
    if (blockIndex < cuConstGraphParams.nSquares) {
        cudaSquare squ = (cudaSquare)cuConstGraphParams.cudaSquares[blockIndex];
        __shared__ uint offX;  
        __shared__ uint offY;  
        __shared__ uint rngX;  
        __shared__ uint rngY;  
        
        __shared__ uint nEdgesToGen;
        if (threadIndex==0)
        {
            offX = (uint)squ.X_start;
            offY = (uint)squ.Y_start;
            rngX = (uint)squ.X_end-offX;
            rngY = (uint)squ.Y_end-offY;
            nEdgesToGen = (uint)squ.nEdgeToGenerate;
            printf("Found Square x: [%u,%u] y: [%u, %u] %u\n", offX,  offX+rngX,offY,offY+rngY, nEdgesToGen);
        }
        __shared__ double A[MAX_DEPTH];
        __shared__ double B[MAX_DEPTH];
        __shared__ double C[MAX_DEPTH];
        __shared__ double D[MAX_DEPTH];

        if (threadIndex==0)
        {
            for (int i = 0; i < MAX_DEPTH; ++i)
            {
                A[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)]);
                B[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i) + 1]);
                C[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)+ 2]);
                D[i] = (double)(cuConstGraphParams.cudaDeviceProbs[4 * (i)+ 3]);
            }
        }
        __syncthreads();
        int minN = min(NUM_CUDA_THREADS, (int)rngX);
        __shared__ uint shared_no_of_outdegs[NUM_CUDA_THREADS];
        __shared__ uint shared_output[NUM_CUDA_THREADS];
        volatile __shared__ uint shared_scratch[2 * NUM_CUDA_THREADS];

        auto applyCondition = directedGraph || ( offX < offY); // true: if the graph is directed or in case it is undirected, the square belongs to the lower triangle of adjacency matrix. false: the diagonal passes the rectangle and the graph is undirected.


        unsigned maxIter = updiv(rngX, blockDim.x); //Divide all sources amongst NUM_CUDA_THREADS
        int N = 2;

        for (unsigned i = 0; i < maxIter; ++i)
        {
            // shared_output[threadIdx.x] = 0;
            // shared_no_of_outdegs[threadIdx.x]= 0;
            int srcIdx = i * blockDim.x + threadIndex+offX;//Interleave sources
            if (srcIdx < rngX+offX )
            {
                double p=nEdgesToGen;
                uint z = srcIdx;
                int j=0;
                uint localrngX = rngX;
                while(localrngX>0) {
                    uint l = z%N;
                    double Ul = A[j]+B[j];
                    if (l==1)
                    {
                      Ul = 1-(A[j]+B[j]);
                    }
                    p= p * Ul;
                    z = z/N;
                    localrngX/=2;
                    j++;
                }
                double ep =p;
                curandState_t localState = states[threadIndex];
                unsigned int X = curand_poisson(&localState, ep);
                shared_no_of_outdegs[threadIndex] = X;
                //Perform prefix_sum
                __syncthreads();
                sharedMemExclusiveScan(threadIndex, shared_no_of_outdegs, shared_output,
                              shared_scratch, minN);
                __syncthreads();
                //BUG: Manual sum of out degrees overflows net edges to generate
                //BUG: Prefix sum not working
                printf("OUTDEGREE %d\n", X);
                // printf("Found out degree %d for net out degree %d for nElements %d\n", X, shared_output[max(minN-1,0)], minN); 
                uint edgeIdx;
                for( edgeIdx = 0; edgeIdx < X ; ) {
                    int2 e;
                    e = get_Edge_indices_PKSG(states, offX, rngX, offY, rngY, srcIdx, A, B, C, D);
                    uint h_idx = e.x;
                    uint v_idx = e.y;
                    printf(" %u Edges Calculated %d \t %d Found Square x: [%u,%u] y: [%u, %u] \n",srcIdx,  e.x,e.y, offX,  offX+rngX,offY,offY+rngY);
                    if( (!applyCondition && h_idx > v_idx) || (!allowEdgeToSelf && h_idx == v_idx ) ) {// Short-circuit if it doesn't pass the test.
                        printf("Err\n"); break;//continue;
                    //BUG: Code Hangs if below two lines included
                    } else if (h_idx< offX || h_idx>= offX+rngX || v_idx < offY || v_idx >= offY+rngY ){
                       printf("Err2\n"); //break;
                       continue;
                    } else {
                    ++edgeIdx;
                    //Write to file
                    }
                }
                printf("Generated %d edges in thread %d in block %d\n", edgeIdx, threadIndex, blockIdx.x );
             }
            __syncthreads();
        }
        __syncthreads();
    }

}

////////////////////////////////////////////////////////////////////////////////////////

GraphGen_Cuda::GraphGen_Cuda() {
    cudaDeviceProbs = NULL;
    cudaDeviceOutput = NULL;
    cudaDeviceSquares = NULL;
    cudaDeviceCompressedOutput = NULL;
    allSquares = NULL;
}


GraphGen_Cuda::~GraphGen_Cuda() {
    if (cudaDeviceProbs) {
        cudaFree(cudaDeviceProbs);
        cudaFree(cudaDeviceOutput);
        cudaFree(cudaDeviceSquares);
        cudaFree(cudaThreadStates);
        cudaFree(cudaDeviceCompressedOutput);
   }
}

int GraphGen_Cuda::setup(
        const uint nEdges,
        const uint nVertices,
        const double RMAT_a, const double RMAT_b, const double RMAT_c,
        const uint standardCapacity,
        const bool allowEdgeToSelf,
        const bool allowDuplicateEdges,
        const bool directedGraph,
        const bool sorted,
        const bool cudaCompressed
    ){
    compressed = cudaCompressed;
    int deviceCount = 0;
    std::string name;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Initializing CUDA for CudaRenderer\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        name = deviceProps.name;

        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n", static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n");
    // By this time the scene should be loaded.  Now copy all the key
    // data structures into device memory so they are accessible to
    // CUDA kernels
    //
    // See the CUDA Programmer's Guide for descriptions of
    // cudaMalloc and cudaMemcpy
    cudacall(cudaMalloc(&cudaDeviceProbs, sizeof(double) * 4 * MAX_DEPTH));
    if(!compressed){
    cudacall(cudaMalloc(&cudaDeviceOutput, sizeof(int) * 2 * nEdges));
    }else{
    cudacall(cudaMalloc(&cudaDeviceCompressedOutput, sizeof(uint) * nEdges));
    }
    GlobalConstants params;

    //Generate Probabilities
    std::uniform_real_distribution<double> distribution(0.0,1.0);
    static std::default_random_engine generator;
    double probs[MAX_DEPTH*4];
    for (int i = 0; i < MAX_DEPTH*4; i+=4) {
        double A = RMAT_a * (distribution(generator)+0.5);
        double B = RMAT_b * (distribution(generator)+0.5);
        double C = RMAT_c *(distribution(generator)+0.5);
        double D = (1- (RMAT_a+RMAT_b+RMAT_c)) *(distribution(generator)+0.5);
        double abcd = A+B+C+D;
        probs[i] = A/abcd;
        probs[i+1] = B/abcd;
        probs[i+2] = C/abcd;
        probs[i+3] = D/abcd;
    }
    
    params.cudaDeviceNumEdges = nEdges ;
    params.cudaDeviceNumVertices = nVertices;
    params.cudaDeviceOutput = cudaDeviceOutput;
    params.cudaDeviceCompressedOutput = cudaDeviceCompressedOutput;
    cudaMemcpy(cudaDeviceProbs, probs, sizeof(double) * 4 * MAX_DEPTH, cudaMemcpyHostToDevice);
    params.cudaDeviceProbs = cudaDeviceProbs;

    //Generate Squares
    std::vector<Square> squares ( 1, Square( 0, nVertices, 0, nVertices, nEdges, 0, 0, 0 ) );
	bool allRecsAreInRange;
	do {
		allRecsAreInRange = true;

		unsigned int recIdx = 0;
		for( auto& rec: squares ) {

			if( Eligible_RNG_Rec(rec, standardCapacity) ) {
				// continue;
			} else {
				ShatterSquare(squares, RMAT_a, RMAT_b, RMAT_c, recIdx, directedGraph);
				allRecsAreInRange = false;
				
				break;
			}
			++recIdx;
		}
	} while( !allRecsAreInRange );

	// Making sure there are enough squares to utilize all blocks and not more
	while( squares.size() < NUM_BLOCKS && !edgeOverflow(squares) ) {
		// Shattering the biggest rectangle.
		uint biggest_size = 0;
		unsigned int biggest_index = 0;
		for( unsigned int x = 0; x < squares.size(); ++x )
			if( squares.at(x).getnEdges() > biggest_size ) {
				biggest_size = squares.at(x).getnEdges();
				biggest_index = x;
			}
		ShatterSquare(squares, RMAT_a, RMAT_b, RMAT_c, biggest_index, directedGraph);
	}

	if (allowDuplicateEdges)
	{
		int originalSize = squares.size();
		for (int index = 0; index < originalSize; ++index)
		{
			//memory leak?
			Square srcRect(squares.at(index));
			// squares.erase(squares.begin()+index);
		
			int numEdgesAssigned = 0;
			int edgesPerSquare = srcRect.getnEdges()/NUM_BLOCKS;
			if (edgesPerSquare< MAX_NUM_EDGES_PER_BLOCK )
			{
				continue;
			}
			for( unsigned int i = 0; i < NUM_BLOCKS-1; ++i ){
				Square destRect(srcRect);
				destRect.setnEdges(edgesPerSquare);
				numEdgesAssigned+=edgesPerSquare;
				squares.push_back(destRect);

			}
			srcRect.setnEdges( srcRect.getnEdges()-numEdgesAssigned);
			squares.at(index) = srcRect;
		}

	
	}
	std::sort(squares.begin(), squares.end(),std::greater<Square>());

    //uint* allSquares = (uint*) malloc(sizeof(uint)* 6 * squares.size());
    allSquares = (cudaSquare*) malloc(sizeof(cudaSquare) * squares.size());
    nSquares = squares.size();
    printf("Generated Squres\n");

    uint tEdges = 0;

    for( unsigned int x = 0; x < squares.size(); ++x ) {
		Square& rec = squares.at( x );
        cudaSquare newSquare;
        newSquare.X_start = rec.get_X_start();
        newSquare.X_end = rec.get_X_end();
        newSquare.Y_start = rec.get_Y_start();
        newSquare.Y_end = rec.get_Y_end();
        newSquare.nEdgeToGenerate = rec.getnEdges();
        newSquare.level = 0;//TODO
        newSquare.recIndex_horizontal = rec.get_H_idx();
        newSquare.recIndex_vertical = rec.get_V_idx();
        newSquare.thisEdgeToGenerate = tEdges;
        memcpy(allSquares+x, &newSquare, sizeof(cudaSquare));
        tEdges += rec.getnEdges();
    }
    printf("Copying Squres\n");
    cudacall(cudaMalloc(&cudaDeviceSquares, sizeof(cudaSquare) * squares.size()));
    cudacall(cudaMemcpy(cudaDeviceSquares, allSquares, sizeof(cudaSquare) * squares.size(), cudaMemcpyHostToDevice));
    params.cudaSquares = cudaDeviceSquares;
    params.nSquares = squares.size();

    /* allocate space on the GPU for the random states */
    cudacall(cudaMalloc((void**) &cudaThreadStates, squares.size()*NUM_CUDA_THREADS * sizeof(curandState_t)));
    params.cudaThreadStates = cudaThreadStates;
    params.allowEdgeToSelf = allowEdgeToSelf;
    params.directedGraph = directedGraph;
    params.sorted = sorted;
    cudaMemcpyToSymbol(cuConstGraphParams, &params, sizeof(GlobalConstants));
    /* invoke the GPU to initialize all of the random states */
    initSorted<<<squares.size(), NUM_CUDA_THREADS>>>(time(0));
    cudaDeviceSynchronize();

    for( unsigned int x = 0; x < squares.size(); ++x ){
        std::cout << squares.at(x);
    }
    std::cout << "CUDA Error " << cudaGetErrorString(cudaGetLastError()) << "\n";
    //free(allSquares);
    return squares.size();
}

void GraphGen_Cuda::generate(const bool directedGraph,
        const bool allowEdgeToSelf, const bool sorted, int squares_size) {
    dim3 nThreads(NUM_CUDA_THREADS,1,1);
    // dim3 gridDim(updivHost(squares_size, blockDim.x));
    dim3 nBlocks(squares_size,1,1);
    printf("Hello launching kernel of blocks %d %d %d and tpb %d %d %d\n", nBlocks.x, nBlocks.y, nBlocks.z, nThreads.x, nThreads.y, nThreads.z);
    if (!compressed)
    KernelGenerateEdges<<<nBlocks, nThreads>>>();
    else
      KernelGenerateEdgesCompressed<<<nBlocks, nThreads>>>();

    cudaDeviceSynchronize();
    std::cout << "CUDA Error " << cudaGetErrorString(cudaGetLastError());
    
    printf("Bye \n");

}

uint GraphGen_Cuda::printGraph(unsigned *Graph, uint nEdges, std::ofstream& outFile) {
  if (!compressed)
  {
    uint x;
    for (x = 0; x < nEdges; x++) {
         outFile << Graph[2*x] << "\t" << Graph[2*x+1] << "\n";
    }
    return x;
  }
  else{
    uint offset=0;
    for (int i = 0; i < nSquares; ++i)
    {
      cudaSquare cs = allSquares[i];
      // std::cout<<i<<"offset"<<cs.thisEdgeToGenerate<<std::endl;
      for (uint j = 0; j < cs.nEdgeToGenerate; ++j)
      {
        uint rngY = (cs.Y_end-cs.Y_start);
        uint offX = cs.X_start;
        uint offY = cs.Y_start;
        // std::cout<<Graph[offset]<<" SQUARE "<< i<<"\n";
        outFile << Graph[offset]/rngY+offX << "\t" << Graph[offset]%rngY+offY << "\n";
        offset++;
      }
    }
    return offset;
  }
    
}

bool GraphGen_Cuda::destroy(){
    //cudaFree(states);
    cudaFree(cudaDeviceProbs);
    cudaFree(cudaDeviceOutput);
    cudaFree(cudaDeviceCompressedOutput);
    return true;
}

void GraphGen_Cuda::getGraph(unsigned* Graph, uint nEdges) {
  if (!compressed)
     cudaMemcpy(Graph, cudaDeviceOutput, sizeof(int)*2*nEdges, cudaMemcpyDeviceToHost);
  else{
     cudaMemcpy(Graph, cudaDeviceCompressedOutput, sizeof(uint)*nEdges, cudaMemcpyDeviceToHost);
   }
}


