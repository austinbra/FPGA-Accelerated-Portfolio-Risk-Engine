#include "rtl_math.h"

#include <algorithm>
#include <array>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace {

constexpr int32_t Q16_ONE = 1 << FRAC_BITS;
constexpr int32_t Q16_HALF = 1 << (FRAC_BITS - 1);
constexpr int32_t LN_CLAMP = static_cast<int32_t>(0xFFEC0000u);
constexpr int LUT_BITS = 12;
constexpr int LUT_SIZE = 1 << LUT_BITS;
constexpr int SIGNED_LUT_SIZE = 1 << (LUT_BITS + 1);
constexpr int EXP_SHIFT = FRAC_BITS - LUT_BITS;
constexpr int32_t EXP_A_MIN = -Q16_ONE;
constexpr int32_t EXP_A_MAX = Q16_ONE - 1;

std::string g_lut_directory;

int32_t wrap32(int64_t value) {
    return static_cast<int32_t>(static_cast<uint32_t>(value));
}

std::string joinPath(const std::string& dir, const std::string& file) {
    if (dir.empty()) return file;
    const char last = dir.back();
    if (last == '/' || last == '\\') return dir + file;
    return dir + "/" + file;
}

bool canOpen(const std::string& path) {
    std::ifstream in(path);
    return in.good();
}

std::string resolveMemFile(const std::string& fileName) {
    std::vector<std::string> candidates;
    if (!g_lut_directory.empty()) {
        candidates.push_back(joinPath(g_lut_directory, fileName));
    }
    candidates.push_back(fileName);
    candidates.push_back(joinPath("src/gen", fileName));
    candidates.push_back(joinPath("../src/gen", fileName));
    candidates.push_back(joinPath("../../src/gen", fileName));
    candidates.push_back(joinPath("../../../src/gen", fileName));

    for (const std::string& candidate : candidates) {
        if (canOpen(candidate)) return candidate;
    }

    throw std::runtime_error("Could not locate RTL LUT file: " + fileName);
}

std::vector<int32_t> loadMemFile(const std::string& fileName, int expectedWords) {
    const std::string path = resolveMemFile(fileName);
    std::ifstream in(path);
    if (!in.is_open()) {
        throw std::runtime_error("Failed to open RTL LUT file: " + path);
    }

    std::vector<int32_t> values;
    values.reserve(expectedWords);
    std::string token;
    while (in >> token) {
        if (token.empty()) continue;
        if (token[0] == '#') {
            std::string rest;
            std::getline(in, rest);
            continue;
        }
        uint32_t raw = 0;
        std::stringstream ss;
        ss << std::hex << token;
        ss >> raw;
        values.push_back(static_cast<int32_t>(raw));
    }

    if (static_cast<int>(values.size()) < expectedWords) {
        throw std::runtime_error("RTL LUT file is shorter than expected: " + path);
    }
    return values;
}

const std::vector<int32_t>& lnLut() {
    static const std::vector<int32_t> lut = loadMemFile("ln_lut_4096.mem", LUT_SIZE);
    return lut;
}

const std::vector<int32_t>& expLut() {
    static const std::vector<int32_t> lut = loadMemFile("exp_lut_4096.mem", LUT_SIZE);
    return lut;
}

const std::vector<int32_t>& expSignedLut() {
    static const std::vector<int32_t> lut = loadMemFile("exp_signed_lut_8192.mem", SIGNED_LUT_SIZE);
    return lut;
}

int32_t saturatingAdd32(int32_t a, int32_t b) {
    const int64_t sum = static_cast<int64_t>(a) + static_cast<int64_t>(b);
    if (sum > std::numeric_limits<int32_t>::max()) {
        return std::numeric_limits<int32_t>::max();
    }
    if (sum < std::numeric_limits<int32_t>::min()) {
        return std::numeric_limits<int32_t>::min();
    }
    return static_cast<int32_t>(sum);
}

} // namespace

void setRtlLutDirectory(const std::string& lutDirectory) {
    g_lut_directory = lutDirectory;
}

int32_t rtlFxDiv(int32_t numerator, int32_t denominator) {
    const int32_t safeDenominator = (denominator == 0) ? Q16_ONE : denominator;
    const int64_t dividend = static_cast<int64_t>(numerator) << FRAC_BITS;
    return wrap32(dividend / safeDenominator);
}

int32_t rtlFxSqrt(int32_t value) {
    if (value <= 0) return 0;

    uint64_t radAcc = (static_cast<uint64_t>(static_cast<uint32_t>(value)) << FRAC_BITS) & ((1ULL << 48) - 1ULL);
    uint32_t root = 0;
    uint64_t rem = 0;

    for (int iter = 0; iter < 24; ++iter) {
        const uint64_t pair = (radAcc >> 46) & 0x3ULL;
        const uint64_t remWide = ((rem & ((1ULL << 26) - 1ULL)) << 2) | pair;
        const uint64_t trial = (static_cast<uint64_t>(root & 0xFFFFFFu) << 2) | 1ULL;
        if (remWide >= trial) {
            rem = remWide - trial;
            root = ((root << 1) | 1u) & 0xFFFFFFu;
        } else {
            rem = remWide;
            root = (root << 1) & 0xFFFFFFu;
        }
        radAcc = (radAcc << 2) & ((1ULL << 48) - 1ULL);
    }

    return static_cast<int32_t>(root & 0xFFFFFFu);
}

int32_t rtlFxLnLut(int32_t value) {
    if (value == 0) return LN_CLAMP;
    const uint32_t addr = (static_cast<uint32_t>(value) >> 4) & 0xFFFu;
    return lnLut()[addr];
}

int32_t rtlFxExpLutUnsigned(int32_t value) {
    const int32_t clamped = std::clamp(value, 0, EXP_A_MAX);
    uint32_t addr = static_cast<uint32_t>(clamped) >> EXP_SHIFT;
    if (addr >= static_cast<uint32_t>(LUT_SIZE)) addr = LUT_SIZE - 1;
    return expLut()[addr];
}

int32_t rtlFxExpLutSigned(int32_t value) {
    const int32_t clamped = std::clamp(value, EXP_A_MIN, EXP_A_MAX);
    uint32_t addr = 0;
    if (value < 0) {
        const int64_t mag = -static_cast<int64_t>(clamped);
        addr = static_cast<uint32_t>(LUT_SIZE + (static_cast<uint64_t>(mag) >> EXP_SHIFT));
        if (addr >= static_cast<uint32_t>(SIGNED_LUT_SIZE)) addr = SIGNED_LUT_SIZE - 1;
    } else {
        addr = static_cast<uint32_t>(clamped) >> EXP_SHIFT;
        if (addr >= static_cast<uint32_t>(LUT_SIZE)) addr = LUT_SIZE - 1;
    }
    return expSignedLut()[addr];
}

int32_t rtlInvCdfZs(int32_t uQ16) {
    constexpr int32_t C0 = 164889; // 2.515517
    constexpr int32_t C1 = 52603;  // 0.802853
    constexpr int32_t C2 = 677;    // 0.010328
    constexpr int32_t D1 = 93896;  // 1.432788
    constexpr int32_t D2 = 12404;  // 0.189269
    constexpr int32_t D3 = 86;     // 0.001308
    constexpr int32_t NEG_TWO = -(2 << FRAC_BITS);

    const bool negate = uQ16 < Q16_HALF;
    const int32_t x = negate ? uQ16 : wrap32(Q16_ONE - static_cast<int64_t>(uQ16));
    const int32_t lnX = rtlFxLnLut(x);
    const int32_t neg2LnX = fxMul(lnX, NEG_TWO);
    const int32_t t = rtlFxSqrt(neg2LnX);

    const int32_t t2 = fxMul(t, t);
    const int32_t t3 = fxMul(t, t2);
    const int32_t c1t = fxMul(C1, t);
    const int32_t c2t2 = fxMul(C2, t2);
    const int32_t d1t = fxMul(D1, t);
    const int32_t d2t2 = fxMul(D2, t2);
    const int32_t d3t3 = fxMul(D3, t3);
    const int32_t numerator = wrap32(static_cast<int64_t>(C0) + c1t + c2t2);
    const int32_t denominator = wrap32(static_cast<int64_t>(Q16_ONE) + d1t + d2t2 + d3t3);
    const int32_t ratio = rtlFxDiv(numerator, denominator);
    const int32_t mag = wrap32(static_cast<int64_t>(t) - ratio);
    return negate ? wrap32(-static_cast<int64_t>(mag)) : mag;
}

int32_t rtlDiscount(int32_t r, int32_t dt) {
    const int32_t negRDt = fxMul(wrap32(-static_cast<int64_t>(r)), dt);
    const int32_t expArg = (negRDt < 0) ? wrap32(-static_cast<int64_t>(negRDt)) : negRDt;
    const int32_t expResult = rtlFxExpLutUnsigned(expArg);
    return rtlFxDiv(Q16_ONE, expResult);
}

int32_t rtlGbmStep(
    int32_t S,
    int32_t driftConst,
    int32_t volSqrtDt,
    int32_t z,
    int32_t* expArgOut,
    int32_t* expOut
) {
    const int32_t volTerm = fxMul(volSqrtDt, z);
    const int32_t expArg = saturatingAdd32(driftConst, volTerm);
    const int32_t expValue = rtlFxExpLutSigned(expArg);
    if (expArgOut) *expArgOut = expArg;
    if (expOut) *expOut = expValue;
    return fxMul(S, expValue);
}
