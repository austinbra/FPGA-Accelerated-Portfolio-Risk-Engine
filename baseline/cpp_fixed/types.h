#ifndef TYPES_H
#define TYPES_H

#include <cstdint>
#include <cmath>
#include <cassert>

constexpr int FRAC_BITS = 16;
constexpr int32_t ONE = 1 << FRAC_BITS;
using Real = double;

inline int32_t toint32_t(double x) {
    double maxRep = static_cast<double>((1 << (31 - FRAC_BITS)) - 1);
    double minRep = -static_cast<double>(1 << (31 - FRAC_BITS));
    if (x > maxRep) x = maxRep;
    if (x < minRep) x = minRep;
    return static_cast<int32_t>(std::llround(x * ONE));
}

inline double toDouble(int32_t x) { return static_cast<double>(x) / ONE; }
inline int32_t fxAdd(int32_t a, int32_t b) { return static_cast<int32_t>(a + b); }
inline int32_t fxSub(int32_t a, int32_t b) { return static_cast<int32_t>(a - b); }

inline int32_t fxMul(int32_t a, int32_t b) {
    int64_t prod = static_cast<int64_t>(a) * static_cast<int64_t>(b);
    prod += (int64_t(1) << (FRAC_BITS - 1));
    return static_cast<int32_t>(prod >> FRAC_BITS);
}

inline int32_t fxDiv(int32_t a, int32_t b) {
    assert(b != 0);
    int64_t num = (static_cast<int64_t>(a) << FRAC_BITS);
    int64_t half_b = (b > 0 ? b : -b) / 2;
    if (num >= 0) num += half_b; else num -= half_b;
    return static_cast<int32_t>(num / b);
}

inline int32_t fxExp(int32_t x) {
    double xd = toDouble(x);
    double ed = std::exp(xd);
    return toint32_t(ed);
}

constexpr int N_DEFAULT = 1024;
constexpr int M_DEFAULT = 12;
constexpr int32_t S0_DEFAULT = int32_t(150 * ONE);
constexpr int32_t K_DEFAULT = int32_t(100 * ONE);
constexpr int32_t r_DEFAULT = int32_t(0.05 * ONE);
constexpr int32_t sigma_DEFAULT = int32_t(0.20 * ONE);
constexpr int32_t T_DEFAULT = int32_t(1.0 * ONE);

#endif
