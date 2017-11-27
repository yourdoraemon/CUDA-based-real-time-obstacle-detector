#include "gpu.h"

#include <stdio.h>


inline static unsigned divup(unsigned n, unsigned div)
{
	return (n + div - 1) / div;
}

void gpuStixelWorld::compute(const cv::Mat & disparity, std::vector<Stixel>& stixels)
{
	CV_Assert(disparity.type() == CV_32F);

	m_rows = disparity.rows;
	m_cols = disparity.cols;

	const int stixelWidth = param_.stixelWidth;
	const int w = m_cols / stixelWidth;
	const int h = m_rows;
	const int fnmax = static_cast<int>(param_.dmax);
	
	float *d_disparity_colReduced = nullptr;
	float *d_disparity_columns = nullptr;

	cudaMalloc((void **)&d_disparity_original, m_rows * m_cols * sizeof(float));
	cudaMalloc((void **)&d_disparity_colReduced, h * w * sizeof(float));
	cudaMalloc((void **)&d_disparity_columns, h * w * sizeof(float));

	float *h_disparity = nullptr;
	if (disparity.isContinuous()) {
		h_disparity = (float*)disparity.data;
	}
	else {
		std::cout << "disparity not continuous\n";
		exit(1);
	}

	cudaMemcpy(d_disparity_original, h_disparity, m_rows * m_cols * sizeof(float), cudaMemcpyHostToDevice);

	dim3 dimBlock(32, 32, 1);
	int r = divup(h, 32); int c = divup(w, 32);
	dim3 dd(divup(h, dimBlock.x), divup(w, dimBlock.y), 1);
	dim3 dimGrid(c, r, 1);

	//columnReductionMean << <dd, dimBlock >> > (d_disparity_original, d_disparity_colReduced, stixelWidth, m_rows, m_cols, w);
	//transposeDisparity <<< dimGrid, dimBlock >>> (d_disparity_colReduced, d_disparity_columns, h, w);

	columnReduction << <dimGrid, dimBlock >> > (d_disparity_original, d_disparity_colReduced, stixelWidth, m_rows, m_cols, w);

	float *data = new float[h * w];
	cudaMemcpy(data, d_disparity_colReduced, h * w * sizeof(float), cudaMemcpyDeviceToHost);
	//cudaMemcpy(data, d_disparity_columns, h * w * sizeof(float), cudaMemcpyDeviceToHost);
	cv::Mat columns = cv::Mat(w, h, CV_32F, data);

	/* for debug */
	//float *tmp_colums = new float[h * w];
	//cudaMemcpy(tmp_colums, d_disparity_colReduced, h * w * sizeof(float), cudaMemcpyDeviceToHost);
	////cudaMemcpy(tmp_colums, d_disparity_columns, h * w * sizeof(float), cudaMemcpyDeviceToHost);

	//cv::Mat mmat(w, h, cv::DataType<float>::type);
	//for (int v = 0; v < h; v++)
	//{
	//	for (int u = 0; u < w; u++)
	//	{
	//		// compute horizontal median
	//		float sum = 0.0f;
	//		for (int du = 0; du < stixelWidth; du++) {
	//			sum += disparity.at<float>(v, u * stixelWidth + du);
	//		}
	//		float m = sum / stixelWidth;
	//		mmat.at<float>(u, h - 1 - v) = m;
	//	}
	//}


	//float *matdata = (float*)mmat.data;
	//for (int k = 0; k < w * h; k++) {
	//	/*if (k > 10000)*/
	//		std::cout << k << ": " << tmp_colums[k] << " " << matdata[k] << "|";
	//}
	int k = 0;

	// get camera parameters
	const CameraParameters& camera = param_.camera;
	const float sinTilt = sinf(camera.tilt);
	const float cosTilt = cosf(camera.tilt);

	// compute expected ground disparity
	//d_groundDisp = nullptr;
	//cudaMalloc((void**)&d_groundDisp, h * sizeof(float));
	////dim3 blocknum(div(h, 32));

	//kernComputeGroundDisp << <divup(h, 32), 32 >> > (d_groundDisp, h, 
	//	camera.baseline, camera.height, camera.fu, camera.v0, sinTilt, cosTilt);
	
	float *h_groundDisp = new float[h];
	cudaMemcpy(h_groundDisp, d_groundDisp, h * sizeof(float), cudaMemcpyDeviceToHost);
	std::vector<float> groundDisparity(h_groundDisp, h_groundDisp + h);
	//std::vector<float> groundDisparity(h);
	//for (int v = 0; v < h; v++) {
	//	groundDisparity[h - 1 - v] = std::max((camera.baseline / camera.height) * (camera.fu * sinTilt + (v - camera.v0) * cosTilt), 0.f);
	//}
	const float vhor = h - 1 - (camera.v0 * cosTilt - camera.fu * sinTilt) / cosTilt;

	//gpuNegativeLogDataTermGrd dataTermG(param_.dmax, param_.dmin, param_.sigmaG, param_.pOutG, param_.pInvG, camera,
	//	d_groundDisp, vhor, param_.sigmaH, param_.sigmaA, h);
	//gpuNegativeLogDataTermObj dataTermO(param_.dmax, param_.dmin, param_.sigmaO, param_.pOutO, param_.pInvO, camera, param_.deltaz);
	//gpuNegativeLogDataTermSky dataTermS(param_.dmax, param_.dmin, param_.sigmaS, param_.pOutS, param_.pInvS);

	const int G = gpuNegativeLogPriorTerm::G;
	const int O = gpuNegativeLogPriorTerm::O;
	const int S = gpuNegativeLogPriorTerm::S;
	gpuNegativeLogPriorTerm priorTerm(h, vhor, param_.dmax, param_.dmin, camera.baseline, camera.fu, param_.deltaz,
		param_.eps, param_.pOrd, param_.pGrav, param_.pBlg, groundDisparity);

	// data cost LUT
	Matrixf costsG(w, h), costsO(w, h, fnmax), costsS(w, h), sum(w, h);
	Matrixi valid(w, h);

	// cost table
	Matrixf costTable(w, h, 3), dispTable(w, h, 3);
	Matrix<cv::Point> indexTable(w, h, 3);

	// process each column
	int u;

	for (u = 0; u < w; u++)
	{
		//////////////////////////////////////////////////////////////////////////////
		// pre-computate LUT
		//////////////////////////////////////////////////////////////////////////////
		float tmpSumG = 0.f;
		float tmpSumS = 0.f;
		std::vector<float> tmpSumO(fnmax, 0.f);

		float tmpSum = 0.f;
		int tmpValid = 0;

		for (int v = 0; v < h; v++)
		{
			// measured disparity
			const float d = columns.at<float>(u, v);
			//const float d = columns(u, v);

			// pre-computation for ground costs
			tmpSumG += m_dataTermG(d, v);
			costsG(u, v) = tmpSumG;

			// pre-computation for sky costs
			tmpSumS += m_dataTermS(d);
			costsS(u, v) = tmpSumS;

			// pre-computation for object costs
			for (int fn = 0; fn < fnmax; fn++)
			{
				tmpSumO[fn] += m_dataTermO(d, fn);
				costsO(u, v, fn) = tmpSumO[fn];
			}

			// pre-computation for mean disparity of stixel
			if (d >= 0.f)
			{
				tmpSum += d;
				tmpValid++;
			}
			sum(u, v) = tmpSum;
			valid(u, v) = tmpValid;
		}

		//////////////////////////////////////////////////////////////////////////////
		// compute cost tables
		//////////////////////////////////////////////////////////////////////////////
		for (int vT = 0; vT < h; vT++)
		{
			float minCostG, minCostO, minCostS;
			float minDispG, minDispO, minDispS;
			cv::Point minPosG(G, 0), minPosO(O, 0), minPosS(S, 0);

			// process vB = 0
			{
				// compute mean disparity within the range of vB to vT
				const float d1 = sum(u, vT) / std::max(valid(u, vT), 1);
				const int fn = cvRound(d1);

				// initialize minimum costs
				minCostG = costsG(u, vT) + priorTerm.getG0(vT);
				minCostO = costsO(u, vT, fn) + priorTerm.getO0(vT);
				minCostS = costsS(u, vT) + priorTerm.getS0(vT);
				minDispG = minDispO = minDispS = d1;
			}

			for (int vB = 1; vB <= vT; vB++)
			{
				// compute mean disparity within the range of vB to vT
				const float d1 = (sum(u, vT) - sum(u, vB - 1)) / std::max(valid(u, vT) - valid(u, vB - 1), 1);
				const int fn = cvRound(d1);

				// compute data terms costs
				const float dataCostG = vT < vhor ? costsG(u, vT) - costsG(u, vB - 1) : N_LOG_0_0;
				const float dataCostO = costsO(u, vT, fn) - costsO(u, vB - 1, fn);
				const float dataCostS = vT < vhor ? N_LOG_0_0 : costsS(u, vT) - costsS(u, vB - 1);

				// compute priors costs and update costs
				const float d2 = dispTable(u, vB - 1, 1);

#define UPDATE_COST(C1, C2) \
				const float cost##C1##C2 = dataCost##C1 + priorTerm.get##C1##C2(vB, cvRound(d1), cvRound(d2)) + costTable(u, vB - 1, C2); \
				if (cost##C1##C2 < minCost##C1) \
				{ \
					minCost##C1 = cost##C1##C2; \
					minDisp##C1 = d1; \
					minPos##C1 = cv::Point(C2, vB - 1); \
				} \

				UPDATE_COST(G, G);
				UPDATE_COST(G, O);
				UPDATE_COST(G, S);
				UPDATE_COST(O, G);
				UPDATE_COST(O, O);
				UPDATE_COST(O, S);
				UPDATE_COST(S, G);
				UPDATE_COST(S, O);
				UPDATE_COST(S, S);
			}

			costTable(u, vT, G) = minCostG;
			costTable(u, vT, O) = minCostO;
			costTable(u, vT, S) = minCostS;

			dispTable(u, vT, G) = minDispG;
			dispTable(u, vT, O) = minDispO;
			dispTable(u, vT, S) = minDispS;

			indexTable(u, vT, G) = minPosG;
			indexTable(u, vT, O) = minPosO;
			indexTable(u, vT, S) = minPosS;
		}
	}

	//////////////////////////////////////////////////////////////////////////////
	// backtracking step
	//////////////////////////////////////////////////////////////////////////////
	for (int u = 0; u < w; u++)
	{
		float minCost = std::numeric_limits<float>::max();
		cv::Point minPos;
		for (int c = 0; c < 3; c++)
		{
			const float cost = costTable(u, h - 1, c);
			if (cost < minCost)
			{
				minCost = cost;
				minPos = cv::Point(c, h - 1);
			}
		}

		while (minPos.y > 0)
		{
			const cv::Point p1 = minPos;
			const cv::Point p2 = indexTable(u, p1.y, p1.x);
			if (p1.x == O) // object
			{
				Stixel stixel;
				stixel.u = stixelWidth * u + stixelWidth / 2;
				stixel.vT = h - 1 - p1.y;
				stixel.vB = h - 1 - (p2.y + 1);
				stixel.width = stixelWidth;
				stixel.disp = dispTable(u, p1.y, p1.x);
				stixels.push_back(stixel);
			}
			minPos = p2;
		}
	}

}

void gpuStixelWorld::preprocess(const CameraParameters & camera, float sinTilt, float cosTilt)
{
	d_groundDisp = nullptr;
	cudaMalloc((void**)&d_groundDisp, m_h * sizeof(float));
	kernComputeGroundDisp << <divup(m_h, 32), 32 >> > (d_groundDisp, m_h,
		camera.baseline, camera.height, camera.fu, camera.v0, sinTilt, cosTilt);

	m_dataTermG = gpuNegativeLogDataTermGrd(param_.dmax, param_.dmin, param_.sigmaG, param_.pOutG, param_.pInvG, camera,
		d_groundDisp, m_vhor, param_.sigmaH, param_.sigmaA, m_h);
	m_dataTermO = gpuNegativeLogDataTermObj(param_.dmax, param_.dmin, param_.sigmaO, param_.pOutO, param_.pInvO, camera, param_.deltaz);
	m_dataTermS = gpuNegativeLogDataTermSky(param_.dmax, param_.dmin, param_.sigmaS, param_.pOutS, param_.pInvS);

}

void gpuStixelWorld::destroy()
{
	cudaFree(d_disparity_original);
	cudaFree(d_disparity_colReduced);
	cudaFree(d_disparity_columns);
	cudaFree(d_groundDisp);
}

void gpuNegativeLogDataTermGrd::init(float dmax, float dmin, float sigmaD, 
	float pOut, float pInv, const CameraParameters & camera, 
	float* d_groundDisparity, float vhor, float sigmaH, float sigmaA, int h)
{
	// uniform distribution term
	nLogPUniform_ = logf(dmax - dmin) - logf(pOut);
	const float cf = camera.fu * camera.baseline / camera.height;

	cudaMalloc((void**)&d_cquad_, h * sizeof(float));
	cudaMalloc((void**)&d_fn_, h * sizeof(float));
	cudaMalloc((void**)&d_nLogPGaussian_, h * sizeof(float));

	dim3 dimBlock(divup(h, 32));
	kernComputeNegativeLogDataTermGrd << <dimBlock,32 >> > (h, d_groundDisparity, d_nLogPGaussian_, d_fn_, d_cquad_,
		camera.fv, camera.tilt, camera.height, cf, sigmaA, sigmaH, sigmaD, dmax, dmin, SQRT2, PI, pOut, vhor);

	float *h_nnLogPGaussian = new float[h];
	float *h_fn = new float[h];
	float *h_cquad = new float[h];

	cudaMemcpy(h_nnLogPGaussian, d_nLogPGaussian_, h * sizeof(float), cudaMemcpyDeviceToHost);
	nLogPGaussian_ = std::vector<float>(h_nnLogPGaussian, h_nnLogPGaussian + h);

	cudaMemcpy(h_fn, d_fn_, h * sizeof(float), cudaMemcpyDeviceToHost);
	fn_ = std::vector<float>(h_fn, h_fn + h);

	cudaMemcpy(h_cquad, d_cquad_, h * sizeof(float), cudaMemcpyDeviceToHost);
	cquad_ = std::vector<float>(h_cquad, h_cquad + h);

	delete[] h_nnLogPGaussian;
	delete[] h_fn;
	delete[] h_cquad;
}

void gpuNegativeLogDataTermGrd::destroy()
{
	cudaFree(d_nLogPGaussian_);
	cudaFree(d_cquad_);
	cudaFree(d_fn_);
}

void gpuNegativeLogDataTermObj::init(float dmax, float dmin, float sigmaD, float pOut, float pInv, const CameraParameters & camera, float deltaz)
{
	// uniform distribution term
	nLogPUniform_ = logf(dmax - dmin) - logf(pOut);

	// Gaussian distribution term
	const int fnmax = static_cast<int>(dmax);

	cudaMalloc((void**)&d_cquad_, fnmax * sizeof(float));
	cudaMalloc((void**)&d_nLogPGaussian_, fnmax * sizeof(float));

	dim3 dimBlock(divup(fnmax, 32));
	kernComputeNegativeLogDataTermObj << <dimBlock, 32 >> > (fnmax, d_cquad_, d_nLogPGaussian_,
		camera.fu, camera.baseline, sigmaD, deltaz, SQRT2, PI, pOut, dmin, dmax);

	float *h_nnLogPGaussian = new float[fnmax];
	float *h_cquad = new float[fnmax];

	cudaMemcpy(h_nnLogPGaussian, d_nLogPGaussian_, fnmax * sizeof(float), cudaMemcpyDeviceToHost);
	nLogPGaussian_ = std::vector<float>(h_nnLogPGaussian, h_nnLogPGaussian + fnmax);

	cudaMemcpy(h_cquad, d_cquad_, fnmax * sizeof(float), cudaMemcpyDeviceToHost);
	cquad_ = std::vector<float>(h_cquad, h_cquad + fnmax);

	delete[] h_nnLogPGaussian;
	delete[] h_cquad;
}

void gpuNegativeLogDataTermSky::init(float dmax, float dmin, float sigmaD, float pOut, float pInv, float fn)
{
	// uniform distribution term
	nLogPUniform_ = logf(dmax - dmin) - logf(pOut);

	// Gaussian distribution term
	const float ANorm = 0.5f * (erff((dmax - fn) / (SQRT2 * sigmaD)) - erff((dmin - fn) / (SQRT2 * sigmaD)));
	nLogPGaussian_ = logf(ANorm) + logf(sigmaD * sqrtf(2.f * PI)) - logf(1.f - pOut);

	// coefficient of quadratic part
	cquad_ = 1.f / (2.f * sigmaD * sigmaD);
}

void gpuNegativeLogPriorTerm::init(int h, float vhor, float dmax, float dmin, float b, float fu, float deltaz, float eps, float pOrd, float pGrav, float pBlg, const std::vector<float>& groundDisparity)

{
	const int fnmax = static_cast<int>(dmax);

	costs0_.create(h, 2);
	costs1_.create(h, 3, 3);
	costs2_O_O_.create(fnmax, fnmax);
	costs2_O_S_.create(1, fnmax);
	costs2_O_G_.create(h, fnmax);
	costs2_S_O_.create(fnmax, fnmax);

	for (int vT = 0; vT < h; vT++)
	{
		const float P1 = N_LOG_1_0;
		const float P2 = -logf(1.f / h);
		const float P3_O = vT > vhor ? N_LOG_1_0 : N_LOG_0_5;
		const float P3_G = vT > vhor ? N_LOG_0_0 : N_LOG_0_5;
		const float P4_O = -logf(1.f / (dmax - dmin));
		const float P4_G = N_LOG_1_0;

		costs0_(vT, O) = P1 + P2 + P3_O + P4_O;
		costs0_(vT, G) = P1 + P2 + P3_G + P4_G;
	}

	for (int vB = 0; vB < h; vB++)
	{
		const float P1 = N_LOG_1_0;
		const float P2 = -logf(1.f / (h - vB));

		const float P3_O_O = vB - 1 < vhor ? N_LOG_0_7 : N_LOG_0_5;
		const float P3_G_O = vB - 1 < vhor ? N_LOG_0_3 : N_LOG_0_0;
		const float P3_S_O = vB - 1 < vhor ? N_LOG_0_0 : N_LOG_0_5;

		const float P3_O_G = vB - 1 < vhor ? N_LOG_0_7 : N_LOG_0_0;
		const float P3_G_G = vB - 1 < vhor ? N_LOG_0_3 : N_LOG_0_0;
		const float P3_S_G = vB - 1 < vhor ? N_LOG_0_0 : N_LOG_0_0;

		const float P3_O_S = vB - 1 < vhor ? N_LOG_0_0 : N_LOG_1_0;
		const float P3_G_S = vB - 1 < vhor ? N_LOG_0_0 : N_LOG_0_0;
		const float P3_S_S = vB - 1 < vhor ? N_LOG_0_0 : N_LOG_0_0;

		costs1_(vB, O, O) = P1 + P2 + P3_O_O;
		costs1_(vB, G, O) = P1 + P2 + P3_G_O;
		costs1_(vB, S, O) = P1 + P2 + P3_S_O;

		costs1_(vB, O, G) = P1 + P2 + P3_O_G;
		costs1_(vB, G, G) = P1 + P2 + P3_G_G;
		costs1_(vB, S, G) = P1 + P2 + P3_S_G;

		costs1_(vB, O, S) = P1 + P2 + P3_O_S;
		costs1_(vB, G, S) = P1 + P2 + P3_G_S;
		costs1_(vB, S, S) = P1 + P2 + P3_S_S;
	}

	for (int d1 = 0; d1 < fnmax; d1++)
		costs2_O_O_(0, d1) = N_LOG_0_0;

	for (int d2 = 1; d2 < fnmax; d2++)
	{
		const float z = b * fu / d2;
		const float deltad = d2 - b * fu / (z + deltaz);
		for (int d1 = 0; d1 < fnmax; d1++)
		{
			if (d1 > d2 + deltad)
				costs2_O_O_(d2, d1) = -logf(pOrd / (d2 - deltad));
			else if (d1 <= d2 - deltad)
				costs2_O_O_(d2, d1) = -logf((1.f - pOrd) / (dmax - d2 - deltad));
			else
				costs2_O_O_(d2, d1) = N_LOG_0_0;
		}
	}

	for (int v = 0; v < h; v++)
	{
		const float fn = groundDisparity[v];
		for (int d1 = 0; d1 < fnmax; d1++)
		{
			if (d1 > fn + eps)
				costs2_O_G_(v, d1) = -logf(pGrav / (dmax - fn - eps));
			else if (d1 < fn - eps)
				costs2_O_G_(v, d1) = -logf(pBlg / (fn - eps - dmin));
			else
				costs2_O_G_(v, d1) = -logf((1.f - pGrav - pBlg) / (2.f * eps));
		}
	}

	for (int d1 = 0; d1 < fnmax; d1++)
	{
		costs2_O_S_(d1) = d1 > eps ? -logf(1.f / (dmax - dmin - eps)) : N_LOG_0_0;
	}

	for (int d2 = 0; d2 < fnmax; d2++)
	{
		for (int d1 = 0; d1 < fnmax; d1++)
		{
			if (d2 < eps)
				costs2_S_O_(d2, d1) = N_LOG_0_0;
			else if (d1 <= 0)
				costs2_S_O_(d2, d1) = N_LOG_1_0;
			else
				costs2_S_O_(d2, d1) = N_LOG_0_0;
		}
	}
}