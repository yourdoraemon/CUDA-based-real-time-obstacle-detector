#include "kernels.h"

//rows and cols are the row number and col number of the UN-transposed matrix
//rows = h, cols = w
__global__ void transposeDisparity(pixel_t * d_input, pixel_t * d_output, int rows, int cols)
{
	__shared__ float mat[32][32 + 1];

	int bx = blockIdx.x * blockDim.x;     
	int by = blockIdx.y * blockDim.y;     
	int i = bx + threadIdx.x;              
	int j = by + threadIdx.y;              

	int ti = by + threadIdx.x;              
	int tj = bx + threadIdx.y;              

	if (i < cols && j < rows)
		mat[threadIdx.y][threadIdx.x] = d_input[j * cols + i];

	__syncthreads();

	if (ti < rows && tj < cols)
		d_output[tj * rows + rows - 1 - ti] = mat[threadIdx.x][threadIdx.y];

}

//rows = m_rows = h, cols = m_cols, c_cols = w
//i: w, j:h
__global__ void columnReduction(pixel_t *d_disparity, pixel_t *d_output,
	int width, int rows, int cols, int c_cols)
{
	__shared__ float mat[32][32 + 1];

	int bx = blockIdx.x * blockDim.x;     
	int by = blockIdx.y * blockDim.y;    
	int i = bx + threadIdx.x;            
	int j = by + threadIdx.y;            

	if (i >= cols || j >= rows) return;

	int ti = by + threadIdx.x;           
	int tj = bx + threadIdx.y;           

	int i_disparity = i * width;
	int index_disparity = j * cols + i * width;

	//compute mean
	float sum = 0.0f;
	for (int di = 0; di < width; ++di) {
		if (i_disparity + di >= cols) continue;
		sum += d_disparity[index_disparity + di];
	}
	sum /= width;

	mat[threadIdx.y][threadIdx.x] = sum;

	__syncthreads();

	if (ti < rows && tj < cols) {
		d_output[tj * rows + rows - 1 - ti] = mat[threadIdx.x][threadIdx.y];
	}
}

//rows = m_rows = h, x(i) dimension, cols = m_cols, c_cols = w y(j) dimension
__global__ void columnReductionMean(pixel_t * d_disparity, pixel_t * d_output, int width, int rows, int cols, int c_cols)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	int jdx = blockIdx.y * blockDim.y + threadIdx.y;

	if (idx >= rows || jdx >= c_cols) {
		return;
	}

	int index_in = idx * c_cols + jdx;

	int index_dis = idx * cols + jdx * width;
	int j_original = jdx * width;

	//TODO use median not mean
	float sum = 0.0f;
	for (int dj = 0; dj < width; ++dj) {
		if (j_original + dj >= cols) continue;
		sum += d_disparity[index_dis + dj];
	}
	sum /= width;

	d_output[index_in] = sum;
}

__global__ void kernComputeGroundDisp(float * d_groundDisp, int h, float baseline, float height, float fu, float v0, float sinTilt, float cosTilt)
{
	int idx = blockDim.x * blockIdx.x + threadIdx.x;
	if (idx >= h) return;

	d_groundDisp[h - 1 - idx] = 0.f;
	float val = baseline / height * (fu * sinTilt + (idx - v0) * cosTilt);
	if (val > 0.f) {
		d_groundDisp[h - 1 - idx] = val;
	}

}

__global__ void kernComputeNegativeLogDataTermGrd(int h, float * d_groundDisparity, float * d_nLogPGaussian_, float * d_fn_, float * d_cquad_, 
	float fv, float tilt, float height, float cf, float sigmaA, float sigmaH, float sigmaD, float dmax, float dmin, float SQRT2, float PI, float pOut, float vhor)
{
	int idx = blockDim.x * blockIdx.x + threadIdx.x;
	if (idx >= h) return;

	const float tmp = ((vhor - idx) / fv + tilt) / height;
	const float sigmaR2 = cf * cf * (tmp * tmp * sigmaH * sigmaH + sigmaA * sigmaA);
	const float sigma = sqrtf(sigmaD * sigmaD + sigmaR2);

	const float fn = d_groundDisparity[idx];
	const float ANorm = 0.5f * (erff((dmax - fn) / (SQRT2 * sigma)) - erff((dmin - fn) / (SQRT2 * sigma)));
	d_nLogPGaussian_[idx] = logf(ANorm) + logf(sigma * sqrtf(2.f * PI)) - logf(1.f - pOut);
	d_fn_[idx] = fn;

	d_cquad_[idx] = 1.f / (2.f * sigma * sigma);
}

__global__ void kernComputeNegativeLogDataTermObj(int fnmax, float * d_cquad_, float * d_nLogPGaussian_, float fu, float baseline, float sigmaD, float deltaz, float SQRT2, float PI, float pOut, float dmin, float dmax)
{
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	if (idx >= fnmax) return;

	const float sigmaZ = idx * idx * deltaz / (fu * baseline);
	const float sigma = sqrtf(sigmaD * sigmaD + sigmaZ * sigmaZ);

	const float ANorm = 0.5f * (erff((dmax - idx) / (SQRT2 * sigma)) - erff((dmin - idx) / (SQRT2 * sigma)));
	d_nLogPGaussian_[idx] = logf(ANorm) + logf(sigma * sqrtf(2.f * PI)) - logf(1.f - pOut);

	d_cquad_[idx] = 1.f / (2.f * sigma * sigma);

}

__global__ void kernComputeCostsG(int m_w, int m_h, float nLogPUniform_, float * d_costsG, float * d_nLogPGaussian_, float * d_cquad_, float * d_fn_, float * d_disp_colReduced)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	int jdx = blockIdx.y * blockDim.y + threadIdx.y;

	if (idx >= m_w || jdx >= m_h) {
		return;
	}
	int pos = idx * m_h + jdx;
	float d = d_disp_colReduced[pos];
	if (d < 0.f) {
		d_costsG[pos] = 0.f;
		return;
	}
	float cost = d_nLogPGaussian_[jdx] + d_cquad_[jdx] * (d - d_fn_[jdx]) * (d - d_fn_[jdx]);

	d_costsG[pos] = imin(nLogPUniform_, cost);

}

__global__ void kernComputeCostsS(int m_w, int m_h, float * d_costsS, float *d_disp_colReduced,  float nLogPUniform_, float cquad_, float nLogPGaussian_, float fn_)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	int jdx = blockIdx.y * blockDim.y + threadIdx.y;

	if (idx >= m_w || jdx >= m_h) {
		return;
	}
	int pos = idx * m_h + jdx;
	float d = d_disp_colReduced[pos];

	if (d < 0.f) {
		d_costsS[pos] = 0.f;
		return;
	}
	float cost = nLogPGaussian_ + cquad_ * (d - fn_) * (d - fn_);

	d_costsS[pos] = imin(nLogPGaussian_, cost);
}

__global__ void kernComputeCostsO(int m_w, int m_h, int fnmax, float * d_costsO, float * d_disp_colReduced, float * d_nLogPGaussian_, float * d_cquad_, float nLogPUniform_)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	int jdx = blockIdx.y * blockDim.y + threadIdx.y;
	int zdx = blockIdx.z * blockDim.z + threadIdx.z;

	if (idx >= m_w || jdx >= m_h || zdx >= fnmax) {
		return;
	}

	int pos = idx * m_h + jdx;
	int val_pos = idx * m_h * fnmax + jdx * fnmax + zdx;

	float d = d_disp_colReduced[pos];
	if (d < 0.f) {
		d_costsO[val_pos] = 0.f;
		return;
	}
	float cost = d_nLogPGaussian_[zdx] + d_cquad_[zdx] * (d - zdx) * (d - zdx);
	d_costsO[val_pos] = imin(nLogPUniform_, cost);
}

__global__ void kernComputeCostsOO(int m_w, int fnmax, int m_h, float * d_costsO, float * d_disp_colReduced, float * d_nLogPGaussian_, float * d_cquad_, float nLogPUniform_)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x; //u
	int jdx = blockIdx.y * blockDim.y + threadIdx.y; //fn
	int zdx = blockIdx.z * blockDim.z + threadIdx.z; //v


	if (idx >= m_w || jdx >= fnmax || zdx >= m_h) {
		return;
	}

	int pos = idx * m_h + zdx;
	int val_pos = idx * m_h * fnmax + jdx * m_h + zdx;

	float d = d_disp_colReduced[pos];
	if (d < 0.f) {
		d_costsO[val_pos] = 0.f;
		return;
	}
	float cost = d_nLogPGaussian_[jdx] + d_cquad_[jdx] * (d - jdx) * (d - jdx);
	if (cost > nLogPUniform_) {
		d_costsO[val_pos] = nLogPUniform_;
	}
	else {
		d_costsO[val_pos] = cost;
	}
}

__global__ void kernScanCosts(int m_w, int m_h, float *d_costsG)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= m_w) return;

	thrust::device_ptr<float> thrust_tmpTerm(d_costsG + idx * m_h);
	thrust::device_ptr<float> thrust_costsG(d_costsG + idx * m_h);

	thrust::inclusive_scan(thrust::device, thrust_tmpTerm, thrust_tmpTerm + m_h, thrust_costsG);
}

__inline__ __device__ float warpSum(float *sums, float value, int lane_id, int warp_id) {

#pragma unroll
	for (int i = 1; i <= 32; i *= 2) {
		float n = __shfl_up(value, i, 32);
		if (lane_id >= i) value += n;
	}

	if (threadIdx.x % warpSize == warpSize - 1) {
		sums[warp_id] = value;
	}

	__syncthreads();

	if (warp_id == 0)
	{
		float warp_sum = sums[lane_id];
		for (int i = 1; i <= 32; i *= 2) {
			float n = __shfl_up(warp_sum, i, 32);
			if (lane_id >= i) warp_sum += n;
		}
		sums[lane_id] = warp_sum;
	}

	__syncthreads();
	float blockSum = 0;
	if (warp_id > 0) {
		blockSum = sums[warp_id - 1];
	}

	value += blockSum;
	return value;
}

__global__ void kernWarpSum(int m_w, int m_h, int fnmax, float *data) {
	int idx = blockIdx.x;
	int jdx = threadIdx.x;
	extern __shared__ int smem[];
	if (jdx >= m_h || idx >= m_w * fnmax) return;

	float *sums = (float*)&smem;
	int lane_id = jdx % warpSize;

	int warp_id = threadIdx.x / warpSize;

	int index = idx * m_h + jdx;
	float value = data[index];
	data[index] = warpSum(sums, value, lane_id, warp_id);
}

__global__ void kernScan2(int m_w, int m_h, int fnmax, float * data)
{
	int idx = blockIdx.x;
	int jdx = threadIdx.x;
	if (jdx >= m_h || idx >= m_w * fnmax) return;
	extern __shared__ int sm[];

	float *s_data = (float*)&sm;
	int l_idx = idx * m_h + jdx;
	int s_idx = jdx;
	s_data[s_idx] = data[l_idx];

	for (unsigned int stride = 1; stride < blockDim.x; stride *= 2) {
		__syncthreads();
		int index = (jdx + 1) * 2 * stride - 1;
		int prev = index - stride;
		if (index < blockDim.x) {
			s_data[index] += s_data[prev];
		}
	}

	for (unsigned int stride = blockDim.x / 4; stride > 0; stride /= 2) {
		__syncthreads();
		int index = (jdx + 1) * 2 * stride - 1;
		int next = index + stride;
		if (next < blockDim.x) {
			s_data[next] += s_data[index];
		}
	}

	__syncthreads();
	data[l_idx] = s_data[s_idx];
}

__global__ void kernScanCostsObj(int m_w, int fnmax, int m_h, float * d_costsO)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x; //u
	int jdx = blockIdx.y * blockDim.y + threadIdx.y; //fn

	if (idx >= m_w || jdx >= fnmax) {
		return;
	}

	thrust::device_ptr<float> thrust_tmpTerm(d_costsO + idx * m_h * fnmax + jdx * m_h);
	thrust::device_ptr<float> thrust_costsG(d_costsO + idx * m_h * fnmax + jdx * m_h);

	thrust::inclusive_scan(thrust::device, thrust_tmpTerm, thrust_tmpTerm + m_h, thrust_costsG);
	
}

__global__ void kerndValid(int m_w, int m_h, float * d_valid)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x; //u
	int jdx = blockIdx.y * blockDim.y + threadIdx.y; //v
	if (idx >= m_w || jdx >= m_h) {
		return;
	}
	int index = idx * m_h + jdx;
	if (d_valid[index] >= 0) {
		d_valid[index] = 1;
	}
	else {
		d_valid[index] = 0;
	}
}

__global__ void kerndSum(int m_w, int m_h, float * d_sum)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x; //u
	int jdx = blockIdx.y * blockDim.y + threadIdx.y; //v
	if (idx >= m_w || jdx >= m_h) {
		return;
	}
	int index = idx * m_h + jdx;
	if (d_sum[index] < 0) {
		d_sum[index] = 0;
	}
}

__global__ void kernScan1shf(int m_w, int m_h, float *data) {
	int idx = blockIdx.x;
	int jdx = threadIdx.x;
	extern __shared__ int smem[];
	if (jdx >= m_h || idx >= m_w ) return;

	float *sums = (float*)&smem;
	int lane_id = jdx % warpSize;

	int warp_id = threadIdx.x / warpSize;

	int index = idx * m_h + jdx;
	float value = data[index];
	data[index] = warpSum(sums, value, lane_id, warp_id);
}

__global__ void kernScan1(int m_w, int m_h, float * data)
{
	int idx = blockIdx.x;
	int jdx = threadIdx.x;
	if (jdx >= m_h || idx >= m_w) return;
	extern __shared__ int sm[];

	float *s_data = (float*)&sm;

	int s_idx = jdx;
	int l_idx = idx * m_h + jdx;
	s_data[s_idx] = data[l_idx];

	for (unsigned int stride = 1; stride < blockDim.x; stride *= 2) {
		__syncthreads();
		int index = (jdx + 1) * 2 * stride - 1;
		int prev = index - stride;
		if (index < blockDim.x) {
			s_data[index] += s_data[prev];
		}
	}

	for (unsigned int stride = blockDim.x / 4; stride > 0; stride /= 2) {
		__syncthreads();
		int index = (jdx + 1) * 2 * stride - 1;
		int next = index + stride;
		if (next < blockDim.x) {
			s_data[next] += s_data[index];
		}
	}

	__syncthreads();
	data[l_idx] = s_data[s_idx];
}

__global__ void KernDP(int m_w, int m_h, int fnmax, float * d_disparity_colReduced, float * d_sum, float * d_valid, 
	float * d_costsG, float * d_costsO, float * d_costsS, float * d_costTableG, float * d_costTableO, float * d_costTableS, 
	float * d_dispTableG, float * d_dispTableO, float * d_dispTableS, 
	glm::vec2 * d_indexTableG, glm::vec2 * d_indexTableO, glm::vec2 * d_indexTableS,
	float *d_costs0_, float *d_costs1_, float *d_costs2_O_G_, float *d_costs2_O_O_, float *d_costs2_O_S_, float *d_costs2_S_O_,
	float N_LOG_0_0, float m_vhor)
{
	extern __shared__ int smem[];

	int u = blockIdx.x; //u
	int jdx = threadIdx.x; //vT

	const int vT = jdx;
	int index = u * m_h + vT;

	float *s_costsG = (float*)&smem;
	float *s_costsS = &s_costsG[m_h];
	float *s_sum = &s_costsS[m_h];
	float *s_valid = &s_sum[m_h];
	//float *s_costsS = &s_costsG[512];
	//float *s_sum = &s_costsS[512];
	//float *s_valid = &s_sum[512];

	float *s_costs1_0 = &s_valid[m_h];
	//float *s_costs1_0 = &s_valid[512];
	float *s_costs1_1 = &s_costs1_0[m_h];
	float *s_costs1_3 = &s_costs1_1[m_h];
	float *s_costs1_4 = &s_costs1_3[m_h];
	float *s_costs1_5 = &s_costs1_4[m_h];
	float *s_costs1_7 = &s_costs1_5[m_h];

	float *s_costTableG = &s_costs1_7[m_h];
	float *s_costTableO = &s_costTableG[m_h];
	float *s_costTableS = &s_costTableO[m_h];

	//float *s_valid_tmp = &s_costTableS[m_h];

	//float val = d_disparity_colReduced[index];
	//s_valid[vT] = val < 0 ? 0 : 1;
	//s_sum[vT] = val < 0 ? 0 : val;
	//s_costsG[vT] = d_costsG[index];
	//s_costsS[vT] = d_costsS[index];

	//for (unsigned int stride = 1; stride < blockDim.x; stride *= 2) {
	//	__syncthreads();
	//	int ind = (jdx + 1) * 2 * stride - 1;
	//	int prev = ind - stride;
	//	if (ind < blockDim.x) {
	//		s_valid[ind] += s_valid[prev];
	//		s_sum[ind] += s_sum[prev];
	//		s_costsG[ind] += s_costsG[prev];
	//		s_costsS[ind] += s_costsS[prev];
	//	}
	//}

	//for (unsigned int stride = blockDim.x / 4; stride > 0; stride /= 2) {
	//	__syncthreads();
	//	int ind = (jdx + 1) * 2 * stride - 1;
	//	int next = ind + stride;
	//	if (next < blockDim.x) {
	//		s_valid[next] += s_valid[ind];
	//		s_sum[next] += s_sum[ind];
	//		s_costsG[next] += s_costsG[ind];
	//		s_costsS[next] += s_costsS[ind];
	//	}
	//}

	if (u >= m_w || jdx >= m_h) return;

	//int lane_id = jdx % warpSize;
	//int warp_id = jdx / warpSize;
	//val = s_valid[vT];
	//s_valid[vT] = warpSum(s_valid_tmp, val, lane_id, warp_id);
	//val = s_sum[vT];
	//s_sum[vT] = warpSum(s_valid_tmp, val, lane_id, warp_id);
	//val = s_costsG[vT];
	//s_costsG[vT] = warpSum(s_valid_tmp, val, lane_id, warp_id);
	//val = s_costsS[vT];
	//s_costsS[vT] = warpSum(s_valid_tmp, val, lane_id, warp_id);

	s_costsG[vT] = d_costsG[index];
	s_costsS[vT] = d_costsS[index];
	s_sum[vT] = d_sum[index];
	s_valid[vT] = d_valid[index];

	s_costs1_0[vT] = d_costs1_[vT + 0];
	s_costs1_1[vT] = d_costs1_[vT + 1];
	s_costs1_3[vT] = d_costs1_[vT + 3];
	s_costs1_4[vT] = d_costs1_[vT + 4];
	s_costs1_5[vT] = d_costs1_[vT + 5];
	s_costs1_7[vT] = d_costs1_[vT + 7];

	float minCostG, minCostO, minCostS;
	float minDispG, minDispO, minDispS;
	glm::vec2 minPosG(0, 0), minPosO(1, 0), minPosS(2, 0);

	// vB = 0;
	{
		__syncthreads();

		const float d1 = s_sum[vT] / imax(s_valid[vT], 1);
		const int fn = static_cast<int>(d1 + 0.5f);

		minCostS = s_costsS[vT] + N_LOG_0_0;
		minCostO = d_costsO[u * fnmax * m_h + fn * m_h + vT] + d_costs0_[vT * 2 + 0];
		minCostG = s_costsG[vT] + d_costs0_[vT * 2 + 1];
		minDispG = minDispO = minDispS = d1;

		s_costTableG[vT] = minCostG;
		s_costTableO[vT] = minCostO;
		s_costTableS[vT] = minCostS;
	}

	for (int vB = 1; vB <= vT; vB++) {
		__syncthreads();
		int vB_idx = u * m_h + vB - 1;
		const float d1 = (s_sum[vT] - s_sum[vB - 1]) / imax(s_valid[vT] - s_valid[vB - 1], 1);
		const int fn = static_cast<int>(d1 + 0.5f);

		const float dataCostG = vT < m_vhor ? s_costsG[vT] - s_costsG[vB - 1] : N_LOG_0_0;
		const float dataCostO = d_costsO[u * fnmax * m_h + fn * m_h + vT] - d_costsO[u * fnmax * m_h + fn * m_h + vB - 1];
		const float dataCostS = vT < m_vhor ? N_LOG_0_0 : s_costsS[vT] - s_costsS[vB - 1];

		const float d2 = d_dispTableO[vB_idx];
		
		int f_d2 = (int)(d2 + 0.5f);
		float c;
		
		c = dataCostG + s_costs1_0[vB] + s_costTableG[vB - 1];
		if (c < minCostG) {
			minCostG = c;
			minDispG = d1;
			minPosG = glm::vec2(0, vB - 1);
		}
		c = dataCostG + s_costs1_1[vB] + s_costTableO[vB - 1];
		if (c < minCostG) {
			minCostG = c;
			minDispG = d1;
			minPosG = glm::vec2(1, vB - 1);
		}
		c = dataCostG + N_LOG_0_0 + s_costTableS[vB - 1];
		if (c < minCostG) {
			minCostG = c;
			minDispG = d1;
			minPosG = glm::vec2(2, vB - 1);
		}
		c = dataCostO + s_costs1_3[vB] + d_costs2_O_G_[(vB - 1) * fnmax + fn] + s_costTableG[vB - 1];
		if (c < minCostO) {
			minCostO = c;
			minDispO = d1;
			minPosO = glm::vec2(0, vB - 1);
		}
		c = dataCostO + s_costs1_4[vB] + d_costs2_O_O_[f_d2 * fnmax + fn] + s_costTableO[vB - 1];
		if (c < minCostO) {
			minCostO = c;
			minDispO = d1;
			minPosO = glm::vec2(1, vB - 1);
		}
		c = dataCostO + s_costs1_5[vB] + d_costs2_O_S_[fn] + s_costTableS[vB - 1];
		if (c < minCostO) {
			minCostO = c;
			minDispO = d1;
			minPosO = glm::vec2(2, vB - 1);
		}
		c = dataCostS + N_LOG_0_0 + s_costTableG[vB - 1];
		if (c < minCostS) {
			minCostS = c;
			minDispS = d1;
			minPosS = glm::vec2(0, vB - 1);
		}
		c = dataCostS + s_costs1_7[vB] + d_costs2_S_O_[f_d2 * fnmax + fn] + s_costTableO[vB - 1];
		if (c < minCostS) {
			minCostS = c;
			minDispS = d1;
			minPosS = glm::vec2(1, vB - 1);
		}
		c = dataCostS + N_LOG_0_0 + s_costTableS[vB - 1];
		if (c < minCostS) {
			minCostS = c;
			minDispS = d1;
			minPosS = glm::vec2(2, vB - 1);
		}

		s_costTableG[vT] = minCostG;
		s_costTableO[vT] = minCostO;
		s_costTableS[vT] = minCostS;
	}

	d_costTableG[index] = s_costTableG[vT];
	d_costTableO[index] = s_costTableO[vT];
	d_costTableS[index] = s_costTableS[vT];

	d_dispTableG[index] = minDispG;
	d_dispTableO[index] = minDispO;
	d_dispTableS[index] = minDispS;

	d_indexTableG[index] = minPosG;
	d_indexTableO[index] = minPosO;
	d_indexTableS[index] = minPosS;


}
