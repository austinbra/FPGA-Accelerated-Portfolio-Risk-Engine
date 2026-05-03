#ifndef PRICING_H
#define PRICING_H

#include <vector>
#include "types.h"
#include "sobol_wrapper.h"

struct Path {
    std::vector<int32_t> S;
    std::vector<int32_t> cashflow;
    Path(int M) : S(M + 1), cashflow(M + 1, 0) {}
};

void setPricingTrace(bool enabled);

void simulatePaths(
    int N, int M,
    int32_t S0, int32_t r, int32_t sigma, int32_t T,
    SobolGenerator& sobol,
    std::vector<Path>& outPaths
);

void backwardInduction(
    int N, int M,
    int32_t r, int32_t T, int32_t K,
    std::vector<Path>& paths,
    int32_t& price_out,
    bool isPut
);

void singleExerciseInduction(
    int N, int M,
    int32_t r, int32_t T, int32_t K,
    std::vector<Path>& paths,
    int32_t& price_out,
    bool isPut
);

void multiExerciseInductionRtlMirror(
    int N, int M,
    int32_t r, int32_t T, int32_t K,
    std::vector<Path>& paths,
    int32_t& price_out,
    bool isPut
);

#endif
