#include <cstdio>
#include <cassert>

#define _CHECK_
//#define _FAT_
//#define _TEXTURES_

struct InfoDPD
{
    int nx, ny, nz, np, nsamples, rsamples_start;
    float XL, YL, ZL;
    float xstart, ystart, zstart,  invrc, aij, gamma, sigmaf;
    float *xyzuvw, *axayaz, *rsamples;
    int * starts;
};

__constant__ InfoDPD info;

#if 0
const int depth = 4;
__device__ int encode(int ix, int iy, int iz) 
{
    int idx = 0;
        
    for(int counter = 0; counter < depth; ++counter)
    {
	const int bitmask = 1 << counter;
	const int idx0 = ix&bitmask;
	const int idx1 = iy&bitmask;
	const int idx2 = iz&bitmask;
            
	idx |= ((idx0<<2*counter) | (idx1<<(2*counter+1)) | (idx2<<(2*counter+2)));
    }
        
    return idx; 
}
	
__device__ int3 decode(int code)
{
    int ix = 0, iy = 0, iz = 0;
        
    for(int counter = 0; counter < depth; ++counter)
    {
	const int bitmask_x = 1 << (counter*3+0);
	const int bitmask_y = 1 << (counter*3+1);
	const int bitmask_z = 1 << (counter*3+2);
	
	ix |= (code&bitmask_x)>>2*counter;
	iy |= (code&bitmask_y)>>(2*counter+1);
	iz |= (code&bitmask_z)>>(2*counter+2);
	    
    }
    return make_int3(ix, iy, iz);
}
#else
__device__ int encode(int ix, int iy, int iz) 
{
    const int retval = ix + info.nx * (iy + iz * info.ny);

    assert(retval < info.nx * info.ny * info.nz && retval>=0);

    return retval; 
}
	
__device__ int3 decode(int code)
{
    const int ix = code % info.nx;
    const int iy = (code / info.nx) % info.ny;
    const int iz = (code / info.nx/info.ny);

    return make_int3(ix, iy, iz);
}
#endif
__global__ void pid2code(int * codes, int * pids)
{
    const int pid = threadIdx.x + blockDim.x * blockIdx.x;

    if (pid >= info.np)
	return;

    const float x = (info.xyzuvw[0 + 6 * pid] - info.xstart) * info.invrc;
    const float y = (info.xyzuvw[1 + 6 * pid] - info.ystart) * info.invrc;
    const float z = (info.xyzuvw[2 + 6 * pid] - info.zstart) * info.invrc;
    
    int ix = (int)floor(x);
    int iy = (int)floor(y);
    int iz = (int)floor(z);
    
    if( !(ix >= 0 && ix < info.nx) ||
	!(iy >= 0 && iy < info.ny) ||
	!(iz >= 0 && iz < info.nz))
	printf("pid %d: oops %f %f %f -> %d %d %d\n", pid, x, y, z, ix, iy, iz);
#if 0 
    assert(ix >= 0 && ix < info.nx);
    assert(iy >= 0 && iy < info.ny);
    assert(iz >= 0 && iz < info.nz);
#else
    ix = max(0, min(info.nx - 1, ix));
    iy = max(0, min(info.ny - 1, iy));
    iz = max(0, min(info.nz - 1, iz));
#endif
    
    codes[pid] = encode(ix, iy, iz);//ix + info.nx * (iy + info.nx * iz);
    pids[pid] = pid;
};



const int xbs = 16;
const int xbs_l = 3;//floor(log2((float)xbs)) -1;
const int ybs = 3;
const int ybs_l = 1;//floor(log2((float)ybs)) -1;
const int xts = xbs;
const int yts = 6;

template <bool vertical>
__device__ float3 _reduce(float3 val)
{
    assert(blockDim.x == xbs);
    assert(blockDim.y == ybs);

    __shared__ float buf[3][ybs][xbs];

    const int tx = threadIdx.x;
    const int ty = threadIdx.y;
    
    buf[0][ty][tx] = val.x;
    buf[1][ty][tx] = val.y;
    buf[2][ty][tx] = val.z;

    __syncthreads();

    if (vertical)
	for(int l = ybs_l; l >= 0; --l)
	{
	    const int L = 1 << l;
	    
	    if (ty < L && ty + L < ybs)
		for(int c = 0; c < 3; ++c)
		    buf[c][ty][tx] += buf[c][ty + L][tx];

	    __syncthreads();
	}
    else
	for(int l = xbs_l; l >= 0; --l)
	{
	    const int L = 1 << l;
	    
	    if (tx < L && tx + L < xbs)
		for(int c = 0; c < 3; ++c)
		    buf[c][ty][tx] += buf[c][ty][tx + L];
	    
	    __syncthreads();
	}	
    
    return make_float3(buf[0][ty][tx], buf[1][ty][tx], buf[2][ty][tx]);
}

__device__ void _ftable(
    float p1[3][yts], float p2[3][xts], float v1[3][yts], float v2[3][xts],
    const int np1, const int np2, const int nonzero_start, const int rsamples_start,
    float a1[3][yts], float a2[3][xts])
{
    assert(np2 <= xts);
    assert(np1 <= yts);
    assert(np1 <= xbs * ybs);
    assert(blockDim.x == xbs && xbs == xts);
    assert(blockDim.y == ybs);

    __shared__ float forces[3][yts][xts];

    const int lx = threadIdx.x;

    if (lx < np2)
	for(int ly = threadIdx.y; ly < np1; ly += blockDim.y)
	{
	    assert(lx < np2 && ly < np1);
	
	    forces[0][ly][lx] = forces[1][ly][lx] = forces[2][ly][lx] = 0;
	
	    if (lx > ly + nonzero_start)
	    {
		float xr = p1[0][ly] - p2[0][lx];
		float yr = p1[1][ly] - p2[1][lx];
		float zr = p1[2][ly] - p2[2][lx];
				
		xr -= info.XL * floorf(0.5f + xr / info.XL);
		yr -= info.YL * floorf(0.5f + yr / info.YL);
		zr -= info.ZL * floorf(0.5f + zr / info.ZL);

		const float rij2 = xr * xr + yr * yr + zr * zr;
		const float invrij = rsqrtf(rij2);
		const float rij = rij2 * invrij;
		const float wr = max((float)0, 1 - rij * info.invrc);
	
		xr *= invrij;
		yr *= invrij;
		zr *= invrij;

		const float rdotv = xr * (v1[0][ly] - v2[0][lx]) + yr * (v1[1][ly] - v2[1][lx]) + zr * (v1[2][ly] - v2[2][lx]);

		int entry = lx + np2 * ly;
		const float myrandnr = info.rsamples[(info.rsamples_start + rsamples_start + entry) % info.nsamples];
#if 0
		assert(myrandnr != -313);
		info.rsamples[(info.rsamples_start + rsamples_start + entry) % info.nsamples] = -313;
#endif

		const float strength = (info.aij - info.gamma * wr * rdotv + info.sigmaf * myrandnr) * wr;
#ifdef _CHECK_
		forces[0][ly][lx] = rij2 < 1;
		forces[1][ly][lx] = 0;
		forces[2][ly][lx] = 0;
#else
		forces[0][ly][lx] = strength * xr;
		forces[1][ly][lx] = strength * yr;
		forces[2][ly][lx] = strength * zr;
#endif
	    }
	}

    __syncthreads();

    {
	float3 v = make_float3(0, 0, 0);

	if (lx < np2)
	    for(int iy = threadIdx.y; iy < np1; iy += blockDim.y)
	    {
		v.x += forces[0][iy][lx];
		v.y += forces[1][iy][lx];
		v.z += forces[2][iy][lx];
	    }

	v = _reduce<true>(v);
	
	if (lx < np2 && threadIdx.y == 0)
	{
	    a2[0][lx] = v.x;
	    a2[1][lx] = v.y;
	    a2[2][lx] = v.z;
	}
    }

    {
	for(int ly = threadIdx.y, base = 0; base < np1; base += blockDim.y, ly += blockDim.y)
	{
	    float3 h = make_float3(0, 0, 0);       
	
	    if (lx < np2 && ly < np1)
		h = make_float3(forces[0][ly][lx],
				forces[1][ly][lx],
				forces[2][ly][lx]);

	    h = _reduce<false>(h);

	    if (lx == 0 && ly < np1)
	    {
		a1[0][ly] += h.x;
		a1[1][ly] += h.y;
		a1[2][ly] += h.z;
	    }
	}
    }
}

texture<float, cudaTextureType1D> texParticles;//, texYP, texZP, texXV, texYV, texZV;

__device__ void _cellcells(const int p1start, const int p1count, const int p2start[4], const int p2counts[4],
			   const bool self, int rsamples_start,
			   float * const axayaz)
{
    __shared__ float pva1[9][yts], pva2[9][xts];

    const int lx = threadIdx.x;
    const int ly = threadIdx.y;
    const int l = lx + blockDim.x * ly;

    const bool master = lx + ly == 0;

    __shared__  int scan[5];

    if (l < 5)
    {
	int s = 0;
	
	for(int i = 0; i < 4; ++i)
	    s += p2counts[i] * (i < l);
		
	scan[l] = s;
    }

    __syncthreads();

    const int p2count = scan[4];
    
    for(int ty = 0; ty < p1count; ty += yts)
    {
	const int np1 = min(yts, p1count - ty);

	assert(blockDim.x * blockDim.y >= np1 * 6);

	if (l < np1 * 6)
	    pva1[l % 6][l / 6] = info.xyzuvw[6 * (p1start + ty) + l];

	if (l < np1 * 3)
	    pva1[6 + (l % 3)][l / 3] = 0;
	
	for(int tx = 0; tx < p2count; tx += xts)
	{
	    const int np2 = min(xts, p2count - tx);
	    
	    if (self && !(tx + xts - 1 > ty))
		continue;

	    for(int i = l; i < np2 * 6; i += blockDim.x * blockDim.y)
	    {
		const int d = i / 6;
		const int s = tx + d;
		const int c = i % 6;
		const int entry = (s >= scan[1]) + (s >= scan[2]) + (s >= scan[3]);
		const int pid = s - scan[entry] + p2start[entry];

		pva2[c][d] = info.xyzuvw[c + 6 * pid];
	    }

	    __syncthreads();

	    _ftable(pva1, pva2, &pva1[3], &pva2[3], np1, np2, self ? ty - tx : - p1count, rsamples_start, &pva1[6], &pva2[6]);

	    rsamples_start += np1 * np2;

	    assert(blockDim.x * blockDim.y >= np2 * 3);
		
	    if (l < np2 * 3)
	    {
		const int s = l / 3;
		const int d = tx + s;
		const int c = l % 3;
		const int entry = (d >= scan[1]) + (d >= scan[2]) + (d >= scan[3]);
		const int pid = d - scan[entry] + p2start[entry];
#ifdef _CHECK_
		axayaz[c + 3 * pid] += pva2[6 + c][s];
#else
		axayaz[c + 3 * pid] -= pva2[6 + c][s];
#endif
	    }	    
	}

	assert(np1 * 3 <= blockDim.x * blockDim.y);
	
	if (l < np1 * 3)
	    axayaz[l + 3 * (p1start + ty)] += pva1[6 + (l % 3)][l / 3];
    }
}

__device__ int _cid(int shiftcode)
{
#ifdef _FAT_
    int3 indx = decode(blockIdx.x / 4 + info.nx * (blockIdx.y + info.ny * blockIdx.z));
#else
    int3 indx = decode(blockIdx.x + info.nx * (blockIdx.y + info.ny * blockIdx.z));
#endif
	    
    indx.x += (shiftcode & 1);
    indx.y += ((shiftcode >> 1) & 1);
    indx.z += ((shiftcode >> 2) & 1);
	    
    indx.x = (indx.x + info.nx) % info.nx;
    indx.y = (indx.y + info.ny) % info.ny;
    indx.z = (indx.z + info.nz) % info.nz;

    return encode(indx.x, indx.y, indx.z);
}

__constant__ int edgeslutcount[4] = {4, 4, 3, 3};
__constant__ int edgeslutstart[4] = {0, 4, 8, 11};
__constant__ int edgeslut[14] = {0, 1, 2, 7, 2, 4, 6, 7, 4, 5, 7, 4, 0, 7};

texture<int, cudaTextureType1D> texStart;

__global__ void _dpd_forces(float * tmp, int * consumed)
{
#ifdef _FAT_
    const int idpass = blockIdx.x % 4;
    const int xcid = blockIdx.x / 4;
    
    const int idbuf = idpass + 4 * ((xcid & 1) | ((blockIdx.y & 1) << 1) | ((blockIdx.z & 1) << 2));

    float * const xa = tmp + info.np * (idbuf + 32 * 0);
    float * const ya = tmp + info.np * (idbuf + 32 * 1);
    float * const za = tmp + info.np * (idbuf + 32 * 2);
#else
    const int idbuf = (blockIdx.x & 1) | ((blockIdx.y & 1) << 1) | ((blockIdx.z & 1) << 2);

    float * const axayaz = tmp + 3 * info.np * idbuf;
#endif
    
    const bool master = threadIdx.x + threadIdx.y == 0;
    const int l = threadIdx.x + blockDim.x * threadIdx.y;
   
    __shared__ int offsetrsamples, rconsumption;
    __shared__ int p2starts[4], p2counts[4];

#ifndef _FAT_
    for(int i = 0; i < 4; ++i)
#else
	const int i = idpass;
#endif
    {
	const int cid1 = _cid(i);
	
	const int s1 = tex1Dfetch(texStart, cid1);
	const int e1 = tex1Dfetch(texStart, cid1 + 1);
	
	const int nentries = edgeslutcount[i];
	const int entrystart = edgeslutstart[i];

	if (master)
	    rconsumption = 0;
	
	assert(4 < warpSize);
	
	if (l < 4)
	    if (l < nentries)
	    {
		const int cid2 = _cid(edgeslut[l + entrystart]);
		assert(!(cid1 == cid2) || i == 0 && l == 0);

		const int s2 = tex1Dfetch(texStart, cid2);
		const int e2 = tex1Dfetch(texStart, cid2 + 1);
	     		
		p2starts[l] = s2;
		p2counts[l] = e2 - s2;

		atomicAdd(&rconsumption, (e1 - s1) * (e2 - s2));
		
	    }
	    else
		p2starts[l] = p2counts[l] = 0;
		
	if (master)
	    offsetrsamples = atomicAdd(consumed, rconsumption);
	    
	__syncthreads();

	if (offsetrsamples + rconsumption >= info.nsamples)
	    //running out of samples. this is bad.
	    return;

	_cellcells(s1, e1 - s1, p2starts, p2counts, i == 0, offsetrsamples, axayaz);
    }
}

__global__ void _reduce(float * tmp)
{
    assert(gridDim.x * blockDim.x >= info.np);
    
    const int tid = threadIdx.x + blockDim.x * blockIdx.x;

    if (tid < info.np * 3)
    {
#ifdef _FAT_
	const int nbufs = 32;
#else
	const int nbufs = 8;
#endif
	float s = 0;
	for(int idbuf = 0; idbuf < nbufs ; ++idbuf)
	    s += tmp[tid + 3 * info.np * idbuf];
	
	info.axayaz[tid] = s;
    }
}

/*
__global__ void aggregate()
{
    const int pid = threadIdx.x + blockDim.x * blockIdx.x;

    if (pid < info.np)
    {
	info.xyzuvw[6 * pid + 0] = info.xp[pid];
	info.xyzuvw[6 * pid + 1] = info.yp[pid];
	info.xyzuvw[6 * pid + 2] = info.zp[pid];
	info.xyzuvw[6 * pid + 3] = info.xv[pid];
	info.xyzuvw[6 * pid + 4] = info.yv[pid];
	info.xyzuvw[6 * pid + 5] = info.zv[pid];
    }
}*/

__global__ void _gather(const float * input, const int * indices, float * output, const int n)
{
    const int tid = threadIdx.x + blockDim.x * blockIdx.x;
    
    if (tid < n)
	output[tid] = input[(tid % 6) + 6 * indices[tid / 6]];
}

#include <cmath>
#include <unistd.h>

#include <curand.h>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/binary_search.h>

using namespace thrust;

#define CUDA_CHECK(ans) do { cudaAssert((ans), __FILE__, __LINE__); } while(0)
inline void cudaAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
    if (code != cudaSuccess) 
    {
	fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
	sleep(5);
	if (abort) exit(code);
    }
}

template<typename T> T * _ptr(device_vector<T>& v) { return raw_pointer_cast(v.data()); }

void _reorder(device_vector<float>& v, device_vector<int>& indx)
{
    assert(v.size() == 6 * indx.size());
    device_vector<float> tmp(v.begin(), v.end());
   
    _gather<<<(v.size() + 127) / 128, 128>>>(_ptr(tmp), _ptr(indx), _ptr(v), v.size());

    CUDA_CHECK(cudaPeekAtLastError());
    CUDA_CHECK(cudaThreadSynchronize());
}

class RRingBuffer
{
    const int n;
    int s, c, olds;
    float * drsamples;
    curandGenerator_t prng;

protected:

    void _refill(int s, int e)
	{
	    assert(e > s && e <= n);
	    
	    const int multiple = 2;

	    s = s - (s % multiple);
	    e = e + (multiple - (e % multiple));
	    e = min(e, n);
	    
	    curandStatus_t res;
	    res = curandGenerateNormal(prng, drsamples + s, e - s, 0, 1);
	    assert(res == CURAND_STATUS_SUCCESS);
	}
    
public:

    RRingBuffer(const int n): n(n), s(0), olds(0), c(0)
	{
	    curandStatus_t res;
	    res = curandCreateGenerator(&prng, CURAND_RNG_PSEUDO_DEFAULT);
	    //we could try CURAND_RNG_PSEUDO_MTGP32 or CURAND_RNG_PSEUDO_MT19937
	    
	    assert(res == CURAND_STATUS_SUCCESS);
	    res = curandSetPseudoRandomGeneratorSeed(prng, 1234ULL);
	    assert(res == CURAND_STATUS_SUCCESS);
	    
	    CUDA_CHECK(cudaMalloc(&drsamples, sizeof(float) * n));

	    update(n);
	    assert(s == 0);
	}

    ~RRingBuffer()
	{
	    CUDA_CHECK(cudaFree(drsamples));
	    curandStatus_t res = curandDestroyGenerator(prng);
	    assert(res == CURAND_STATUS_SUCCESS);
	}
    
    void update(const int consumed)
	{
	    assert(consumed >= 0 && consumed <= n);

	    c += consumed;
	    assert(c >= 0 && c <= n);
	    
	    if (c > 0.45 * n)
	    {
		const int c1 = min(olds + c, n) - olds;
	    
		if (c1 > 0)
		    _refill(olds, olds + c1);

		const int c2 = c - c1;

		if (c2 > 0)
		    _refill(0, c2);
	    
		olds = (olds + c) % n;
		s = olds;
		c = 0;
	    }
	    else
		s = (olds + c) % n;
	}

    int start() const { return s; }
    float * buffer() const { return drsamples; }
    int nsamples() const { return n; }
};

struct SetupTexs
{
    SetupTexs()
	{
	    cudaChannelFormatDesc fmt =  cudaCreateChannelDesc(32, 0, 0, 0, cudaChannelFormatKindSigned);
	    texStart.channelDesc = fmt;
	    texStart.filterMode = cudaFilterModePoint;
	    texStart.mipmapFilterMode = cudaFilterModePoint;
	    texStart.normalized = 0;
	    
	    fmt =  cudaCreateChannelDesc(32, 0, 0, 0, cudaChannelFormatKindFloat);
	    texParticles.channelDesc = fmt;
	    texParticles.filterMode = cudaFilterModePoint;
	    texParticles.mipmapFilterMode = cudaFilterModePoint;
	    texParticles.normalized = 0;
	}
} setuptexs;

struct ProfileComputation
{
    int count;
    float tf, tr, tt;
    cudaEvent_t evstart, evforce, evreduce;

    ProfileComputation(): count(0), tf(0), tr(0), tt(0)
	{
	    CUDA_CHECK(cudaEventCreate(&evstart));
	    CUDA_CHECK(cudaEventCreate(&evforce));
	    CUDA_CHECK(cudaEventCreate(&evreduce));
	}

    ~ProfileComputation()
	{
	    CUDA_CHECK(cudaEventDestroy(evstart));
	    CUDA_CHECK(cudaEventDestroy(evforce));
	    CUDA_CHECK(cudaEventDestroy(evreduce));
	}

    void start() { CUDA_CHECK(cudaEventRecord(evstart));  }
    void force() { CUDA_CHECK(cudaEventRecord(evforce));  }
    void reduce() { CUDA_CHECK(cudaEventRecord(evreduce)); }
    
    void stop()
	{
	    
	    CUDA_CHECK(cudaEventSynchronize(evreduce));
	    float tforce, treduce, ttotal;
	    CUDA_CHECK(cudaEventElapsedTime(&tforce, evstart, evforce));
	    CUDA_CHECK(cudaEventElapsedTime(&treduce, evforce, evreduce));
	    CUDA_CHECK(cudaEventElapsedTime(&ttotal, evstart, evreduce));
	    
	    tf += tforce;
	    tr += treduce;
	    tt += ttotal;
	    count++;
	    
	    if (count % 100 == 0)
	    {
		printf("times: %.2f ms %.2f ms -> F %.1f%%\n", tf/count, tr/count, tf/tt * 100);
	    }
	}
} ;

ProfileComputation * _myprof;

void forces_dpd_cuda(/*float * const _xp, float * const _yp, float * const _zp,
		       float * const _xv, float * const _yv, float * const _zv,*/
    float * const _xyzuvw,
		     float * const _axayaz, 
		     //float * const _xa, float * const _ya, float * const _za,
		     int * const order, const int np,
		     const float rc,
		     const float XL, const float YL, const float ZL,
		     const float aij,
		     const float gamma,
		     const float sigma,
		     const float invsqrtdt,
		     float * const _rsamples, int nsamples)
{
    static bool initialized = false;

    if (!initialized)
    {
	cudaDeviceProp prop;
	cudaGetDeviceProperties(&prop, 0);
	if (!prop.canMapHostMemory)
	{
	    printf("Capability zero-copy not there! Aborting now.\n");
	    abort();
	}
	else
	    cudaSetDeviceFlags(cudaDeviceMapHost);

	initialized = true;
    }

    static RRingBuffer * rrbuf = NULL;

    if (rrbuf == NULL)
	rrbuf = new RRingBuffer(50 * np * 3);

    if (_myprof == NULL)
	_myprof = new ProfileComputation();

    ProfileComputation& myprof = *_myprof;
     
    int nx = (int)ceil(XL / rc);
    int ny = (int)ceil(YL / rc);
    int nz = (int)ceil(ZL / rc);
    const int ncells = nx * ny * nz;
    
    device_vector<int> starts(ncells + 1);
    device_vector<float> xyzuvw(_xyzuvw, _xyzuvw + np * 6), axayaz(np * 3);
    
    InfoDPD c;
    c.nx = nx;
    c.ny = ny;
    c.nz = nz;
    c.np = np;
    c.XL = XL;
    c.YL = YL;
    c.ZL = ZL;
    c.xstart = -XL * 0.5; 
    c.ystart = -YL * 0.5; 
    c.zstart = -ZL * 0.5; 
    c.invrc = 1.f / rc;
    c.aij = aij;
    c.gamma = gamma;
    c.sigmaf = sigma * invsqrtdt;
    c.xyzuvw = _ptr(xyzuvw);
    c.axayaz = _ptr(axayaz);
    c.nsamples = rrbuf->nsamples();
    c.rsamples = rrbuf->buffer();
    c.rsamples_start = rrbuf->start();

    device_vector<float> rsamples;
    if (_rsamples != NULL)
    {
	rsamples.resize(nsamples);
	copy(_rsamples, _rsamples + nsamples, rsamples.begin());

	c.nsamples = nsamples;
	c.rsamples = _ptr(rsamples);
	c.rsamples_start = 0;
    }
    else
	nsamples = rrbuf->nsamples();
    
    c.starts = _ptr(starts);
    
    CUDA_CHECK(cudaMemcpyToSymbol(info, &c, sizeof(c)));

    device_vector<int> codes(np), pids(np);
    pid2code<<<(np + 127) / 128, 128>>>(_ptr(codes), _ptr(pids));

    sort_by_key(codes.begin(), codes.end(), pids.begin());
    
    _reorder(xyzuvw, pids);
    
    device_vector<int> cids(ncells + 1);
    //createseq<<<ncells
    sequence(cids.begin(), cids.end());

    lower_bound(codes.begin(), codes.end(), cids.begin(), cids.end(), starts.begin());

    int * consumed = NULL;
    cudaHostAlloc((void **)&consumed, sizeof(int), cudaHostAllocMapped);
    assert(consumed != NULL);
    *consumed = 0;
    
    {
	size_t textureoffset = 0;
	cudaChannelFormatDesc fmt =  cudaCreateChannelDesc(32, 0, 0, 0, cudaChannelFormatKindSigned);
	cudaBindTexture(&textureoffset, &texStart, c.starts, &fmt, sizeof(int) * (ncells + 1));
	fmt =  cudaCreateChannelDesc(32, 0, 0, 0, cudaChannelFormatKindFloat);
	cudaBindTexture(&textureoffset, &texParticles, c.xyzuvw, &fmt, sizeof(float) * 6 * np);

	float * tmp;

#ifdef _FAT_
	const int nreplica = 96;
#else
	const int nreplica = 24;
#endif
	CUDA_CHECK(cudaMalloc(&tmp, sizeof(float) * np * nreplica));
	CUDA_CHECK(cudaMemset(tmp, 0, sizeof(float) * np * nreplica));
	
	int * dconsumed = NULL;
	cudaHostGetDevicePointer(&dconsumed, consumed, 0);

	myprof.start();
	
#ifdef _FAT_
	_dpd_forces<<<dim3(4 * c.nx, c.ny, c.nz), dim3(xbs, ybs, 1)>>>(tmp, dconsumed);
#else
	_dpd_forces<<<dim3(c.nx, c.ny, c.nz), dim3(xbs, ybs, 1)>>>(tmp, dconsumed);
#endif

	myprof.force();
	CUDA_CHECK(cudaPeekAtLastError());

	_reduce<<<(3 * np + 127) / 128, 128>>>(tmp);
	myprof.reduce();
	CUDA_CHECK(cudaPeekAtLastError());
	
	CUDA_CHECK(cudaFree(tmp));
	
	if (*consumed >= nsamples)
	{
	    printf("done with code %d: consumed: %d\n", 7, *consumed);
	    printf("not a nice situation.\n");
	    //abort();
	}

	//printf("consumed: %d\n", *consumed);
    }

    myprof.stop();
    
#ifdef _CHECK_
    CUDA_CHECK(cudaThreadSynchronize());
    for(int i = 0; i < np; ++i)
	;//assert((float)xa[i] > 0);

    //printf("positivity test passed\n");
    
    for(int i = 0; i < np; ++i)
    {
	printf("pid %d -> %f %f %f\n", i, (float)axayaz[0 + 3 * i], (float)axayaz[1 + 3* i], (float)axayaz[2 + 3 *i]);

	int cnt = 0;
	const int pid = pids[i];

	printf("devi coords are %f %f %f\n", (float)xyzuvw[0 + 6 * i], (float)xyzuvw[1 + 6 * i], (float)xyzuvw[2 + 6 * i]);
	printf("host coords are %f %f %f\n", (float)_xyzuvw[0 + 6 * pid], (float)_xyzuvw[1 + 6 * pid], (float)_xyzuvw[2 + 6 * pid]);
	
	
	for(int j = 0; j < np; ++j)
	{
	    if (pid == j)
		continue;
 
	    float xr = _xyzuvw[0 + 6 * pid] - _xyzuvw[0 + 6 * j];
	    float yr = _xyzuvw[1 + 6 * pid] - _xyzuvw[1 + 6 * j];
	    float zr = _xyzuvw[2 + 6 * pid] - _xyzuvw[2 + 6 * j];

	    xr -= c.XL *  ::floor(0.5f + xr / c.XL);
	    yr -= c.YL *  ::floor(0.5f + yr / c.YL);
	    zr -= c.ZL *  ::floor(0.5f + zr / c.ZL);

	    const float rij2 = xr * xr + yr * yr + zr * zr;
	    

	    cnt += rij2 < 1;
	}
	printf("i found %d host interactions and with cuda i found %d\n", cnt, (int)axayaz[0 + 3 * i]);
	assert(cnt == (float)axayaz[0 + 3 * i]);

	//sleep(3);
    }
    printf("test done.\n");
    sleep(1);
    exit(0);
#endif

	
    if (_rsamples == NULL)
	rrbuf->update(*consumed);
    
    cudaFreeHost(consumed);
    
    /*copy(xp.begin(), xp.end(), _xp);
    copy(yp.begin(), yp.end(), _yp);
    copy(zp.begin(), zp.end(), _zp);
	
    copy(xv.begin(), xv.end(), _xv);
    copy(yv.begin(), yv.end(), _yv);
    copy(zv.begin(), zv.end(), _zv);*/

    /*copy(xa.begin(), xa.end(), _xa);
      copy(ya.begin(), ya.end(), _ya);
      copy(za.begin(), za.end(), _za);*/
    copy(xyzuvw.begin(), xyzuvw.end(), _xyzuvw);
    copy(axayaz.begin(), axayaz.end(), _axayaz);

    if (order != NULL)
	copy(pids.begin(), pids.end(), order);
}