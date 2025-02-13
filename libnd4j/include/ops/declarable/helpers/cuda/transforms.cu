/*
 *  ******************************************************************************
 *  *
 *  *
 *  * This program and the accompanying materials are made available under the
 *  * terms of the Apache License, Version 2.0 which is available at
 *  * https://www.apache.org/licenses/LICENSE-2.0.
 *  *
 *  * See the NOTICE file distributed with this work for additional
 *  * information regarding copyright ownership.
 *  * Unless required by applicable law or agreed to in writing, software
 *  * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 *  * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *  * License for the specific language governing permissions and limitations
 *  * under the License.
 *  *
 *  * SPDX-License-Identifier: Apache-2.0
 *  *****************************************************************************
 */

//
// @author Yurii Shyrma (iuriish@yahoo.com), created on 20.04.2018
//

#include <array/NDArrayFactory.h>
#include <array/ResultSet.h>
#include <exceptions/cuda_exception.h>
#include <helpers/ConstantTadHelper.h>
#include <helpers/PointersManager.h>
#include <helpers/ShapeUtils.h>
#include <helpers/TAD.h>
#include <ops/declarable/helpers/transforms.h>

#include <numeric>

namespace sd {
namespace ops {
namespace helpers {

///////////////////////////////////////////////////////////////////
template <typename T>
SD_KERNEL static void invertPermutationCuda(const void* vx, const sd::LongType* xShapeInfo, void* vz,
                                            const sd::LongType* zShapeInfo) {
  const T* x = reinterpret_cast<const T*>(vx);
  T* z = reinterpret_cast<T*>(vz);

  __shared__ sd::LongType len, totalThreads;

  if (threadIdx.x == 0) {
    len = shape::length(xShapeInfo);
    totalThreads = gridDim.x * blockDim.x;
  }

  __syncthreads();

  const auto tid = blockIdx.x * blockDim.x + threadIdx.x;

  for (sd::LongType i = tid; i < len; i += totalThreads) {
    const auto xOffset = shape::getIndexOffset(i, xShapeInfo);
    const sd::LongType index = x[xOffset];
    const auto zOffset = shape::getIndexOffset(index, zShapeInfo);
    z[zOffset] = i;
  }
}

///////////////////////////////////////////////////////////////////
template <typename T>
SD_HOST static void invertPermutationCudaLauncher(const int blocksPerGrid, const int threadsPerBlock,
                                                  const cudaStream_t* stream, const void* vx,
                                                  const sd::LongType* xShapeInfo, void* vz,
                                                  const sd::LongType* zShapeInfo) {
  invertPermutationCuda<T><<<blocksPerGrid, threadsPerBlock, 1024, *stream>>>(vx, xShapeInfo, vz, zShapeInfo);
}

////////////////////////////////////////////////////////////////////////
void invertPermutation(sd::LaunchContext* context, const NDArray& input, NDArray& output) {
  const int threadsPerBlock = SD_MAX_NUM_THREADS;
  const int blocksPerGrid = (input.lengthOf() + threadsPerBlock - 1) / threadsPerBlock;

  PointersManager manager(context, "invertPermutation");

  NDArray::prepareSpecialUse({&output}, {&input});
  BUILD_SINGLE_SELECTOR(input.dataType(), invertPermutationCudaLauncher,
                        (blocksPerGrid, threadsPerBlock, context->getCudaStream(), input.specialBuffer(),
                         input.specialShapeInfo(), output.specialBuffer(), output.specialShapeInfo()),
                        SD_COMMON_TYPES);
  NDArray::registerSpecialUse({&output}, {&input});

  manager.synchronize();
}

//////////////////////////////////////////////////////////////////////////
template <typename T>
SD_KERNEL static void traceCuda(const void* vx, const sd::LongType* xShapeInfo, void* vz,
                                const sd::LongType* zShapeInfo, const sd::LongType diagLen) {
  const auto x = reinterpret_cast<const T*>(vx);
  auto z = reinterpret_cast<T*>(vz);

  __shared__ T sharedMem[SD_CUDA_BLOCK_SIZE];
  __shared__ int xRank, zRank;  // xRank = zRank + 2
  __shared__ sd::LongType xLen, zLen;

  if (threadIdx.x == 0) {
    xRank = shape::rank(xShapeInfo);
    zRank = shape::rank(zShapeInfo);
    xLen = shape::length(xShapeInfo);
    zLen = shape::length(zShapeInfo);  // corresponds to number of matrices
  }
  __syncthreads();

  sd::LongType coords[SD_MAX_RANK];

  for (sd::LongType m = blockIdx.x; m < zLen;
       m += gridDim.x) {  // one block per each element of z, that is per each matrix

    shape::index2coords(m, zShapeInfo, coords);
    const auto zOffset = shape::getOffset(zShapeInfo, coords);

    sharedMem[threadIdx.x] = 0;

    for (sd::LongType i = threadIdx.x; i < diagLen; i += blockDim.x) {
      coords[zRank] = coords[zRank + 1] = i;
      const auto xOffset = shape::getOffset(xShapeInfo, coords);
      sharedMem[threadIdx.x] += x[xOffset];
    }

    __syncthreads();

    // aggregate sum
    for (sd::LongType activeThreads = blockDim.x / 2; activeThreads > 0; activeThreads /= 2) {
      if (threadIdx.x < activeThreads) sharedMem[threadIdx.x] += sharedMem[threadIdx.x + activeThreads];
      __syncthreads();
    }

    if (threadIdx.x == 0) z[zOffset] = *sharedMem;
    __syncthreads();
  }
}

///////////////////////////////////////////////////////////////////
template <typename T>
static void traceCudaLauncher(const int blocksPerGrid, const int threadsPerBlock, const int sharedMem,
                              const cudaStream_t* stream, const void* vx, const sd::LongType* xShapeInfo, void* vz,
                              const sd::LongType* zShapeInfo, const sd::LongType diagLen) {
  traceCuda<T><<<blocksPerGrid, threadsPerBlock, sharedMem, *stream>>>(vx, xShapeInfo, vz, zShapeInfo, diagLen);
}

///////////////////////////////////////////////////////////////////
void trace(sd::LaunchContext* context, const NDArray& input, NDArray& output) {
  PointersManager manager(context, "trace");

  const sd::LongType diagLen = input.sizeAt(-1) < input.sizeAt(-2) ? input.sizeAt(-1) : input.sizeAt(-2);
  const int threadsPerBlock = SD_CUDA_BLOCK_SIZE;
  const int blocksPerGrid = (output.lengthOf() + threadsPerBlock - 1) / threadsPerBlock;
  const int sharedMem = 1024;

  NDArray::prepareSpecialUse({&output}, {&input});
  BUILD_SINGLE_SELECTOR(input.dataType(), traceCudaLauncher,
                        (blocksPerGrid, threadsPerBlock, sharedMem, context->getCudaStream(), input.specialBuffer(),
                         input.specialShapeInfo(), output.specialBuffer(), output.specialShapeInfo(), diagLen),
                        SD_COMMON_TYPES);
  NDArray::registerSpecialUse({&output}, {&input});

  manager.synchronize();
}

///////////////////////////////////////////////////////////////////
template <typename T>
SD_KERNEL static void triuBPCuda(const void* vx, const sd::LongType* xShapeInfo, void* vz,
                                 const sd::LongType* zShapeInfo, const int diag) {
  // x and z have same shapes
  const auto x = reinterpret_cast<const T*>(vx);  // gradO
  auto z = reinterpret_cast<T*>(vz);              // gradI

  __shared__ int rank, areSameOffsets;
  __shared__ sd::LongType len, totalThreads;  // xLen = zLen

  if (threadIdx.x == 0) {
    areSameOffsets = shape::haveSameShapeAndStrides(xShapeInfo, zShapeInfo);
    rank = shape::rank(xShapeInfo);
    len = shape::length(zShapeInfo);
    totalThreads = gridDim.x * blockDim.x;
  }

  __syncthreads();

  sd::LongType coords[SD_MAX_RANK];

  const sd::LongType  tid = blockIdx.x * blockDim.x + threadIdx.x;

  for (sd::LongType i = tid; i < len; i += totalThreads) {
    shape::index2coords(i, zShapeInfo, coords);

    const auto zOffset = shape::getOffset(zShapeInfo, coords);

    if ((coords[rank - 2] + diag > coords[rank - 1]))  // row + diag > col
      z[zOffset] = 0;
    else
      z[zOffset] = x[areSameOffsets ? zOffset : shape::getOffset(xShapeInfo, coords)];
  }
}

///////////////////////////////////////////////////////////////////
template <typename T>
static void triuBPCudaLauncher(const int blocksPerGrid, const int threadsPerBlock, const int sharedMem,
                               const cudaStream_t* stream, const void* vx, const sd::LongType* xShapeInfo, void* vz,
                               const sd::LongType* zShapeInfo, const int diag) {
  triuBPCuda<T><<<blocksPerGrid, threadsPerBlock, sharedMem, *stream>>>(vx, xShapeInfo, vz, zShapeInfo, diag);
}

///////////////////////////////////////////////////////////////////
void triuBP(sd::LaunchContext* context, const NDArray& input, const NDArray& gradO, NDArray& gradI,
            const int diagonal) {
  const int threadsPerBlock = SD_MAX_NUM_THREADS / 4;
  const int blocksPerGrid = (gradO.lengthOf() + threadsPerBlock - 1) / threadsPerBlock;
  const int sharedMem = threadsPerBlock * sizeof(sd::LongType) * gradO.rankOf() + 128;

  PointersManager manager(context, "triuBP");

  NDArray::prepareSpecialUse({&gradI}, {&gradO});
  BUILD_SINGLE_SELECTOR(gradI.dataType(), triuBPCudaLauncher,
                        (blocksPerGrid, threadsPerBlock, sharedMem, context->getCudaStream(), gradO.specialBuffer(),
                         gradO.specialShapeInfo(), gradI.specialBuffer(), gradI.specialShapeInfo(), diagonal),
                        SD_COMMON_TYPES);
  NDArray::registerSpecialUse({&gradI}, {&gradO});

  manager.synchronize();
}

///////////////////////////////////////////////////////////////////
template <typename T>
SD_KERNEL static void tileBPCuda(const void* vx, const sd::LongType* xShapeInfo, void* vz,
                                 const sd::LongType* zShapeInfo, sd::LongType* globMem) {
  // x and z have same shapes
  const auto x = reinterpret_cast<const T*>(vx);  // gradO
  auto z = reinterpret_cast<T*>(vz);              // gradI

  __shared__ int xRank, zRank;                                // xRank >= zRank
  __shared__ sd::LongType numOfXOffsets, zLen, totalThreads;  // xLen >= zLen

  if (threadIdx.x == 0) {
    xRank = shape::rank(zShapeInfo);
    zLen = shape::length(zShapeInfo);
    numOfXOffsets = shape::length(xShapeInfo) / zLen;

    totalThreads = gridDim.x * blockDim.x;
  }

  __syncthreads();

  const auto tid = blockIdx.x * blockDim.x + threadIdx.x;

  sd::LongType memBuff[SD_MAX_RANK * 2];
  auto xOffsets = globMem + tid * numOfXOffsets;

  for (sd::LongType i = tid; i < zLen; i += totalThreads) {
    const auto zOffset = shape::getIndexOffset(i, zShapeInfo);

    shape::outerArrayOffsets(xOffsets, i, xShapeInfo, zShapeInfo, memBuff);

    z[zOffset] = x[xOffsets[0]];                      // first offset
    for (sd::LongType j = 1; j < numOfXOffsets; ++j)  // rest offsets
      z[zOffset] += x[xOffsets[j]];
  }
}

///////////////////////////////////////////////////////////////////
template <typename T>
static void tileBPCudaLauncher(const int blocksPerGrid, const int threadsPerBlock, const int sharedMem,
                               const cudaStream_t* stream, const void* vx, const sd::LongType* xShapeInfo, void* vz,
                               const sd::LongType* zShapeInfo, sd::LongType* globMem) {
  tileBPCuda<T><<<blocksPerGrid, threadsPerBlock, sharedMem, *stream>>>(vx, xShapeInfo, vz, zShapeInfo, globMem);
}

//////////////////////////////////////////////////////////////////////////
void tileBP(sd::LaunchContext* context, const NDArray& gradO /*input*/, NDArray& gradI /*output*/,
            const std::vector<sd::LongType> reps) {
  NDArray memBuff(
      'c', gradO.getShapeAsVector(), sd::DataType::INT64,
      context);  // empty auxiliary array for storing device memory which will be used in kernel calculations

  const int threadsPerBlock = SD_MAX_NUM_THREADS / 4;
  const int blocksPerGrid = (gradI.lengthOf() + threadsPerBlock - 1) / threadsPerBlock;
  const int sharedMem = threadsPerBlock * sizeof(sd::LongType) * 2 * gradO.rankOf() + 128;

  PointersManager manager(context, "tileBP");

  NDArray::prepareSpecialUse({&gradI}, {&gradO, &memBuff});
  BUILD_SINGLE_SELECTOR(gradI.dataType(), tileBPCudaLauncher,
                        (blocksPerGrid, threadsPerBlock, sharedMem, context->getCudaStream(), gradO.specialBuffer(),
                         gradO.specialShapeInfo(), gradI.specialBuffer(), gradI.specialShapeInfo(),
                         reinterpret_cast<sd::LongType*>(memBuff.specialBuffer())),
                        SD_FLOAT_TYPES);
  NDArray::registerSpecialUse({&gradI}, {&gradO, &memBuff});

  manager.synchronize();
}

//////////////////////////////////////////////////////////////////////////
void eye(sd::LaunchContext* context, NDArray& output) { output.setIdentity(); }

}  // namespace helpers
}  // namespace ops
}  // namespace sd
