#ifndef SOBOL_WRAPPER_H
#define SOBOL_WRAPPER_H

#include <vector>
#include <cstdint>
#include <string>
#include "types.h"

struct SobolSample {
    uint32_t raw;
    int32_t q16;
    Real u;
};

class SobolGenerator {
public:
    SobolGenerator(int dimension, std::uint32_t skip = 0, const std::string& directionFile = "");
    std::vector<SobolSample> nextPointDetailed();
    std::vector<Real> nextPoint();
    uint32_t sobolRaw(uint32_t index, int dimension) const;
    static int32_t q16FromRaw(uint32_t raw);

private:
    int dim_;
    std::uint32_t skip_;
    std::uint32_t pointIndex_;
    std::vector<uint32_t> direction_;
};

#endif
