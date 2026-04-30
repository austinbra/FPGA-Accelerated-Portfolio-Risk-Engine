#include "linalg.h"
#include "rtl_math.h"
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>

static void solve3x3System(const double A_in[3][3], const double B_in[3], double beta[3]) {
    double aug[3][4];
    for (int i = 0; i < 3; ++i) {
        aug[i][0] = A_in[i][0];
        aug[i][1] = A_in[i][1];
        aug[i][2] = A_in[i][2];
        aug[i][3] = B_in[i];
    }

    for (int pivot = 0; pivot < 3; ++pivot) {
        int best_row = pivot;
        double best_val = std::fabs(aug[pivot][pivot]);
        for (int r = pivot + 1; r < 3; ++r) {
            double val = std::fabs(aug[r][pivot]);
            if (val > best_val) {
                best_val = val;
                best_row = r;
            }
        }
        if (best_val < 1e-12) {
            std::cerr << "solve3x3System: pivot too small or det = 0.\n";
            return;
        }

        if (best_row != pivot) {
            for (int c = pivot; c < 4; ++c) std::swap(aug[pivot][c], aug[best_row][c]);
        }

        double diag = aug[pivot][pivot];
        for (int c = pivot; c < 4; ++c) aug[pivot][c] /= diag;

        for (int r = pivot + 1; r < 3; ++r) {
            double factor = aug[r][pivot];
            if (std::fabs(factor) < 1e-12) continue;
            for (int c = pivot; c < 4; ++c) aug[r][c] -= factor * aug[pivot][c];
        }
    }

    for (int r = 2; r >= 0; --r) {
        double value = aug[r][3];
        for (int c = r + 1; c < 3; ++c) value -= aug[r][c] * beta[c];
        beta[r] = value;
    }
}

void solveRegression3x3(const std::vector<int32_t>& X, const std::vector<int32_t>& Y, int32_t beta_out[3]) {
    int n = static_cast<int>(X.size());
    assert(n == static_cast<int>(Y.size()));

    int64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0;
    int64_t sy = 0, sxy = 0, sx2y = 0;

    for (int i = 0; i < n; ++i) {
        int32_t x = X[i];
        int32_t y = Y[i];
        int32_t x2 = fxMul(x, x);
        int32_t x3 = fxMul(x2, x);
        int32_t x4 = fxMul(x2, x2);
        int32_t xy = fxMul(x, y);
        int32_t x2y = fxMul(x2, y);
        s0 += ONE; s1 += x; s2 += x2; s3 += x3; s4 += x4;
        sy += y; sxy += xy; sx2y += x2y;
    }

    double A[3][3] = {
        {toDouble((int32_t)s0), toDouble((int32_t)s1), toDouble((int32_t)s2)},
        {toDouble((int32_t)s1), toDouble((int32_t)s2), toDouble((int32_t)s3)},
        {toDouble((int32_t)s2), toDouble((int32_t)s3), toDouble((int32_t)s4)}
    };
    double B[3] = {
        toDouble((int32_t)sy),
        toDouble((int32_t)sxy),
        toDouble((int32_t)sx2y)
    };

    double beta_d[3] = {0.0, 0.0, 0.0};
    solve3x3System(A, B, beta_d);
    beta_out[0] = toint32_t(beta_d[0]);
    beta_out[1] = toint32_t(beta_d[1]);
    beta_out[2] = toint32_t(beta_d[2]);
}

namespace {

using RtlMat = std::array<std::array<int32_t, 4>, 3>;

int32_t wrap32(int64_t value) {
    return static_cast<int32_t>(static_cast<uint32_t>(value));
}

int32_t absRtl(int32_t value) {
    return value < 0 ? wrap32(-static_cast<int64_t>(value)) : value;
}

int32_t saturate32(int64_t value) {
    if (value > INT32_MAX) return INT32_MAX;
    if (value < INT32_MIN) return INT32_MIN;
    return static_cast<int32_t>(value);
}

std::array<int32_t, 12> buildRtlMatrix(const std::vector<int32_t>& X, const std::vector<int32_t>& Y) {
    int64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0;
    int64_t sy = 0, sxy = 0, sx2y = 0;

    for (std::size_t i = 0; i < X.size(); ++i) {
        const int32_t x = X[i];
        const int32_t y = Y[i];
        const int32_t x2 = fxMul(x, x);
        const int32_t x3 = fxMul(x2, x);
        const int32_t x4 = fxMul(x2, x2);
        const int32_t xy = fxMul(x, y);
        const int32_t x2y = fxMul(x2, y);
        s0 += ONE;
        s1 += x;
        s2 += x2;
        s3 += x3;
        s4 += x4;
        sy += y;
        sxy += xy;
        sx2y += x2y;
    }

    return {
        saturate32(s0), saturate32(s1), saturate32(s2), saturate32(sy),
        saturate32(s1), saturate32(s2), saturate32(s3), saturate32(sxy),
        saturate32(s2), saturate32(s3), saturate32(s4), saturate32(sx2y),
    };
}

void fallbackMean(const std::array<int32_t, 12>& flat, int32_t beta_out[3]) {
    beta_out[0] = rtlFxDiv(flat[3], flat[0]);
    beta_out[1] = 0;
    beta_out[2] = 0;
}

} // namespace

void solveRegression3x3Rtl(const std::vector<int32_t>& X, const std::vector<int32_t>& Y, int32_t beta_out[3]) {
    assert(X.size() == Y.size());

    const std::array<int32_t, 12> flat = buildRtlMatrix(X, Y);
    RtlMat mat0{};
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 4; ++c) {
            mat0[r][c] = flat[r * 4 + c];
        }
    }

    int pivot0 = 0;
    const int32_t a00 = absRtl(mat0[0][0]);
    const int32_t a10 = absRtl(mat0[1][0]);
    const int32_t a20 = absRtl(mat0[2][0]);
    if (a10 > a00) pivot0 = 1;
    if ((pivot0 == 0 ? a20 > a00 : a20 > a10)) pivot0 = 2;

    RtlMat mat1{};
    mat1[0] = mat0[pivot0];
    mat1[1] = (pivot0 == 1) ? mat0[0] : mat0[1];
    mat1[2] = (pivot0 == 2) ? mat0[0] : mat0[2];
    if (mat1[0][0] == 0) {
        fallbackMean(flat, beta_out);
        return;
    }

    RtlMat mat2{};
    for (int c = 0; c < 4; ++c) {
        mat2[0][c] = rtlFxDiv(mat1[0][c], mat1[0][0]);
        mat2[1][c] = mat1[1][c];
        mat2[2][c] = mat1[2][c];
    }

    RtlMat mat3{};
    for (int c = 0; c < 4; ++c) {
        const int32_t elim1 = fxMul(mat2[1][0], mat2[0][c]);
        const int32_t elim2 = fxMul(mat2[2][0], mat2[0][c]);
        mat3[0][c] = mat2[0][c];
        mat3[1][c] = wrap32(static_cast<int64_t>(mat2[1][c]) - elim1);
        mat3[2][c] = wrap32(static_cast<int64_t>(mat2[2][c]) - elim2);
    }

    int pivot1 = 1;
    if (absRtl(mat3[2][1]) > absRtl(mat3[1][1])) pivot1 = 2;

    RtlMat mat4{};
    mat4[0] = mat3[0];
    mat4[1] = mat3[pivot1];
    mat4[2] = (pivot1 == 2) ? mat3[1] : mat3[2];
    if (mat4[1][1] == 0) {
        fallbackMean(flat, beta_out);
        return;
    }

    RtlMat mat5{};
    mat5[0] = mat4[0];
    mat5[1][0] = mat4[1][0];
    for (int c = 1; c < 4; ++c) {
        mat5[1][c] = rtlFxDiv(mat4[1][c], mat4[1][1]);
    }
    mat5[2] = mat4[2];

    RtlMat mat6{};
    mat6[0] = mat5[0];
    mat6[1] = mat5[1];
    mat6[2][0] = mat5[2][0];
    for (int c = 1; c < 4; ++c) {
        const int32_t elim = fxMul(mat5[2][1], mat5[1][c]);
        mat6[2][c] = wrap32(static_cast<int64_t>(mat5[2][c]) - elim);
    }
    if (mat6[2][2] == 0) {
        fallbackMean(flat, beta_out);
        return;
    }

    RtlMat mat7{};
    mat7[0] = mat6[0];
    mat7[1] = mat6[1];
    mat7[2][0] = mat6[2][0];
    for (int c = 1; c < 4; ++c) {
        mat7[2][c] = rtlFxDiv(mat6[2][c], mat6[2][2]);
    }

    const int32_t bt2 = rtlFxDiv(mat7[2][3], mat7[2][2]);
    const int32_t prod12 = fxMul(mat7[1][2], bt2);
    const int32_t rhs1 = wrap32(static_cast<int64_t>(mat7[1][3]) - prod12);
    const int32_t bt1 = rtlFxDiv(rhs1, mat7[1][1]);
    const int32_t prod01 = fxMul(mat7[0][1], bt1);
    const int32_t prod02 = fxMul(mat7[0][2], bt2);
    const int32_t rhs0 = wrap32(static_cast<int64_t>(mat7[0][3]) - prod01 - prod02);
    const int32_t bt0 = rtlFxDiv(rhs0, mat7[0][0]);

    beta_out[0] = bt0;
    beta_out[1] = bt1;
    beta_out[2] = bt2;
}
