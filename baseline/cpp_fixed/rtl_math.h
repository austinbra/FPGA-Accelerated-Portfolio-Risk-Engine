#ifndef RTL_MATH_H
#define RTL_MATH_H

#include "types.h"
#include <cstdint>
#include <string>

void setRtlLutDirectory(const std::string& lutDirectory);

int32_t rtlFxDiv(int32_t numerator, int32_t denominator);
int32_t rtlFxSqrt(int32_t value);
int32_t rtlFxLnLut(int32_t value);
int32_t rtlFxExpLutUnsigned(int32_t value);
int32_t rtlFxExpLutSigned(int32_t value);
int32_t rtlInvCdfZs(int32_t uQ16);
int32_t rtlDiscount(int32_t r, int32_t dt);
int32_t rtlGbmStep(
    int32_t S,
    int32_t driftConst,
    int32_t volSqrtDt,
    int32_t z,
    int32_t* expArgOut = nullptr,
    int32_t* expOut = nullptr
);

#endif
