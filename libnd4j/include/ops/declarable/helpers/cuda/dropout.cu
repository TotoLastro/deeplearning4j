/* ******************************************************************************
 *
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 *  See the NOTICE file distributed with this work for additional
 *  information regarding copyright ownership.
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ******************************************************************************/

//
//  @author raver119@gmail.com
//
#include <exceptions/cuda_exception.h>
#include <legacy/NativeOps.h>
#include <ops/declarable/helpers/dropout.h>

#include <memory>
#include <vector>

namespace sd {
namespace ops {
namespace helpers {

template <typename T>
static SD_KERNEL void dropoutSimpleKernel(void const* inputBuf, sd::LongType const* inputShape, void* outputBuf,
                                          sd::LongType const* outputShape, double probVal, int inLen,
                                          sd::graph::RandomGenerator* nodeRng) {
  auto tid = blockIdx.x * blockDim.x + threadIdx.x;
  auto step = blockDim.x * gridDim.x;
  T const* input = reinterpret_cast<T const*>(inputBuf);
  T* output = reinterpret_cast<T*>(outputBuf);

  // trivial idea: loop through all elements, get independent probability for each element to be nullified
  for (sd::LongType e = 0; e < inLen; ++e) {
    T val = nodeRng->relativeT(e, T(0.f), T(1.f));

    // if probability is ok - we're saving scaled value
    if (double(val) < probVal)
      output[shape::getIndexOffset(e, outputShape)] = T(input[shape::getIndexOffset(e, inputShape)] / probVal);
  }
}

template <typename T>
static void dropoutSimple(sd::LaunchContext* context, NDArray const* input, NDArray* output, double probValue,
                          int seed) {
  sd::graph::RandomGenerator nodeRng(3019L, seed);
  int inLen = input->lengthOf();
  sd::graph::RandomGenerator* dRandom;
  auto stream = context->getCudaStream();
  NDArray::prepareSpecialUse({output}, {input});

  auto err = cudaMalloc(&dRandom, sizeof(sd::graph::RandomGenerator));
  if (err) {
    throw cuda_exception::build("helpers::dropoutSimple: Cannot allocate device memory for random generator.", err);
  }
  err = cudaMemcpy(dRandom, &nodeRng, sizeof(sd::graph::RandomGenerator), cudaMemcpyHostToDevice);
  if (err) {
    throw cuda_exception::build("helpers::dropoutSimple: Cannot set up device memory for random generator.", err);
  }

  dropoutSimpleKernel<T><<<128, 256, 1024, *stream>>>(input->specialBuffer(), input->specialShapeInfo(),
                                                      output->specialBuffer(), output->specialShapeInfo(), probValue,
                                                      inLen, dRandom);
  err = cudaFree(dRandom);
  if (err) {
    throw cuda_exception::build("helpers::dropoutSimple: Cannot deallocate device memory for random generator.", err);
  }
  NDArray::registerSpecialUse({output}, {input});
}

template <typename T>
sd::Status _dropOutFunctor(graph::Context& context, NDArray* input, NDArray* output, NDArray* reduceShape, int seed,
                           double probValue) {
  if (reduceShape == nullptr) {
    dropoutSimple<T>(context.launchContext(), input, output, probValue, seed);
  } else {
    REQUIRE_TRUE(reduceShape->lengthOf() <= input->rankOf(), 0, "dropout: Noise shape should be fittable to input");

    std::vector<sd::LongType> dims(reduceShape->lengthOf());
    reduceShape->syncToHost();  // to ensure that follows are actual
    bool fit = true;

    for (int i = 0; i < dims.size(); i++) {
      if (fit) {
        dims[i] = reduceShape->e<sd::LongType>(i);
        for (int e = 0; e < input->rankOf(); ++e)
          if (fit)
            if (input->sizeAt(e) % dims[i]) {
              fit = false;
            }
      }
    }

    // check dims to fit input
    REQUIRE_TRUE(fit, 0, "dropout: Noise shape should fit to input rank.");
    std::unique_ptr<NDArray> chunk(new NDArray('c', dims, output->dataType(), context.launchContext()));
    chunk->assign(1.f);

    dropoutSimple<T>(context.launchContext(), chunk.get(), chunk.get(), probValue, seed);
    // broadcast chunk to full matrix
    std::unique_ptr<NDArray> dropOutMultiplier(new NDArray(*input));
    dropOutMultiplier->assign(1.f);

    *dropOutMultiplier += *chunk;

    // FIXME: we could do this in one step, aren't we?
    output->assign(*input * *dropOutMultiplier);  // input->applyPairwiseTransform(pairwise::Multiply,
                                                  // dropOutMultiplier.get(), output, nullptr);
  }

  return sd::Status::OK;
}

sd::Status dropOutFunctor(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* output,
                          sd::NDArray* reduceShape, int seed, double probValue, sd::NDArray* mask) {
  auto xType = input->dataType();
  NDArray::prepareSpecialUse({output}, {input});

  BUILD_SINGLE_SELECTOR(xType, return _dropOutFunctor, (context, input, output, reduceShape, seed, probValue),
                        SD_FLOAT_TYPES);

  NDArray::registerSpecialUse({output}, {input});
}

/////////////////////////////////// backrpopagations ///////////////////////////////////////////////
template <typename T>
static SD_KERNEL void dropoutBPKernel(void* outputBuf, sd::LongType const* outputShape, void* gradOutBuf,
                                      sd::LongType const* gradOutShape, double probValue) {
  __shared__ T* output;
  __shared__ T* input;
  __shared__ int len;

  if (threadIdx.x == 0) {
    len = shape::length(outputShape);
    output = reinterpret_cast<T*>(outputBuf);
    input = reinterpret_cast<T*>(gradOutBuf);
  }
  __syncthreads();

  auto tid = blockIdx.x * blockDim.x + threadIdx.x;
  auto step = blockDim.x * gridDim.x;

  for (int e = tid; e < len; e += step) {
    const auto zOffset = shape::getIndexOffset(e, outputShape);

    // if probability was non-zero on FF step, we'll scale grads back
    if (output[zOffset] != T(0.)) output[zOffset] = T(input[shape::getIndexOffset(e, gradOutShape)] / probValue);
  }
}
template <typename T>
static sd::Status dropOutFunctorBP_(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* gradOut,
                                    sd::NDArray* output, sd::NDArray* reduceShape, int seed, double probValue,
                                    sd::NDArray* mask) {
  // we're making additional FF run to see how probabilities played out with given seeds
  auto res = dropOutFunctor(context, input, output, reduceShape, seed, probValue,mask);
  auto stream = context.launchContext()->getCudaStream();

  NDArray::prepareSpecialUse({output}, {input, gradOut});

  if (sd::Status::OK == res)
    dropoutBPKernel<T><<<128, 256, 1024, *stream>>>(output->specialBuffer(), output->specialShapeInfo(),
                                                    gradOut->specialBuffer(), gradOut->specialShapeInfo(), probValue);

  NDArray::registerSpecialUse({output}, {input, gradOut});

  return res;
}

template <typename T>
static SD_KERNEL void alphaDropoutSimpleKernel(void const* inputBuf, sd::LongType const* inputShape, void* outputBuf,
                                               sd::LongType const* outputShape, double probValue, double alpha,
                                               double alpha1, double beta, int inLen,
                                               sd::graph::RandomGenerator* nodeRng) {
  auto tid = blockIdx.x * blockDim.x + threadIdx.x;
  auto step = blockDim.x * gridDim.x;
  T const* input = reinterpret_cast<T const*>(inputBuf);
  T* output = reinterpret_cast<T*>(outputBuf);

  for (auto e = tid; e < inLen; e += step) {
    T val = nodeRng->relativeT(e, T(0.f), T(1.f));
    T xVal = input[shape::getIndexOffset(e, inputShape)];
    output[shape::getIndexOffset(e, outputShape)] =
        (val >= T(probValue) ? T(alpha * beta + alpha1) : T(alpha * (double)xVal + alpha1));
  }
}
template <typename T>
static void alphaDropoutSimple(sd::LaunchContext* context, NDArray const* input, NDArray* output, int seed,
                               double probValue, double alpha, double alpha1, double beta) {
  sd::graph::RandomGenerator nodeRng(3019L, seed), *dRandom;
  auto stream = context->getCudaStream();
  auto err = cudaMalloc(&dRandom, sizeof(sd::graph::RandomGenerator));
  NDArray::prepareSpecialUse({output}, {input});
  if (err) {
    throw cuda_exception::build("helpers::alphaDropoutSimple: Cannot allocate device memory for random generator.",
                                err);
  }
  err = cudaMemcpy(dRandom, &nodeRng, sizeof(sd::graph::RandomGenerator), cudaMemcpyHostToDevice);
  if (err) {
    throw cuda_exception::build("helpers::alphaDropoutSimple: Cannot set up device memory for random generator.", err);
  }

  alphaDropoutSimpleKernel<T><<<128, 256, 1024, *stream>>>(input->specialBuffer(), input->specialShapeInfo(),
                                                           output->specialBuffer(), output->specialShapeInfo(),
                                                           probValue, alpha, alpha1, beta, output->lengthOf(), dRandom);

  err = cudaFree(dRandom);
  if (err) {
    throw cuda_exception::build("helpers::alphaDropoutSimple: Cannot deallocate device memory for random generator.",
                                err);
  }
  NDArray::registerSpecialUse({output}, {input});
}

template <typename T>
static sd::Status alphaDropOutFunctor_(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* output,
                                       sd::NDArray* reduceShape, int seed, double probValue, double alpha,
                                       double alpha1, double beta, sd::NDArray* mask) {
  if (reduceShape == nullptr) {
    alphaDropoutSimple<T>(context.launchContext(), input, output, seed, probValue, alpha, alpha1, beta);
  } else {
    REQUIRE_TRUE(reduceShape->lengthOf() <= input->rankOf(), 0, "dropout: Noise shape should be fittable to input");

    std::vector<sd::LongType> dims(reduceShape->lengthOf());
    reduceShape->syncToHost();  // to ensure that follows are actual
    bool fit = true;

    for (int i = 0; i < dims.size(); i++) {
      if (fit) {
        dims[i] = reduceShape->e<sd::LongType>(i);
        for (int e = 0; e < input->rankOf(); ++e)
          if (fit)
            if (input->sizeAt(e) % dims[i]) {
              fit = false;
            }
      }
    }

    // check dims to fit input
    REQUIRE_TRUE(fit, 0, "alpha_dropout: Noise shape should fit to input rank.");
    std::unique_ptr<NDArray> chunk(new NDArray('c', dims, output->dataType(), context.launchContext()));
    chunk->assign(1.f);

    alphaDropoutSimple<T>(context.launchContext(), chunk.get(), chunk.get(), seed, probValue, alpha, alpha1, beta);

    // broadcast chunk to full matrix
    std::unique_ptr<NDArray> dropOutMultiplier(new NDArray(*input));
    dropOutMultiplier->assign(1.f);

    *dropOutMultiplier += *chunk;

    output->assign(*input * *dropOutMultiplier);

  }

  return sd::Status::OK;
}

template <typename T>
sd::Status alphaDropOutFunctorBP_(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* gradOut,
                                  sd::NDArray* output, sd::NDArray* reduceShape, int seed, double probValue,
                                  double alpha, double alpha1, double beta, sd::NDArray* mask) {
  auto res = alphaDropOutFunctor(context, input, output, reduceShape, seed, probValue, alpha, alpha1, beta,mask);
  if (res == sd::Status::OK) {
    // FIXME: can we make it single-loop?
    (*output) *= alpha;
    (*output) *= (*gradOut);
  }
  return res;
}

sd::Status dropOutFunctorBP(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* gradOut, sd::NDArray* output,
                            sd::NDArray* reduceShape, int seed, double probValue, sd::NDArray* mask) {
  BUILD_SINGLE_SELECTOR(context.dataType(), return dropOutFunctorBP_,
                        (context, input, gradOut, output, reduceShape, seed, probValue,mask), SD_FLOAT_TYPES);
}

sd::Status alphaDropOutFunctor(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* output,
                               sd::NDArray* reduceShape, int seed, double probValue, double alpha, double alpha1,
                               double beta, sd::NDArray* mask) {
  BUILD_SINGLE_SELECTOR(context.dataType(), return alphaDropOutFunctor_,
                        (context, input, output, reduceShape, seed, probValue, alpha, alpha1, beta,mask), SD_FLOAT_TYPES);
}

sd::Status alphaDropOutFunctorBP(sd::graph::Context& context, sd::NDArray* input, sd::NDArray* gradOut,
                                 sd::NDArray* output, sd::NDArray* reduceShape, int seed, double probValue,
                                 double alpha, double alpha1, double beta, sd::NDArray* mask) {
  BUILD_SINGLE_SELECTOR(context.dataType(), return alphaDropOutFunctorBP_,
                        (context, input, gradOut, output, reduceShape, seed, probValue, alpha, alpha1, beta,mask),
                        SD_FLOAT_TYPES);
}

}  // namespace helpers
}  // namespace ops
}  // namespace sd
