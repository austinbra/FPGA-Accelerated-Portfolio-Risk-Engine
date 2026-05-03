#include "pricing.h"
#include "linalg.h"
#include "rtl_math.h"
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <iomanip>
#include <iostream>

static bool g_pricing_trace = false;
static constexpr double REGRESSION_BETA_ABS_CAP = 4096.0;

void setPricingTrace(bool enabled) {
    g_pricing_trace = enabled;
}

static void trace32(const char* stage, const char* key, int32_t value, int path = -1, int step = -1, const char* pass = nullptr) {
    if (!g_pricing_trace) return;
    std::cout << "[NUM][" << stage << "]";
    if (pass) std::cout << " pass=" << pass;
    if (path >= 0) std::cout << " path=" << path;
    if (step >= 0) std::cout << " step=" << step;
    std::cout << " key=" << key
              << " value=0x" << std::uppercase << std::hex << std::setw(8) << std::setfill('0')
              << static_cast<uint32_t>(value)
              << std::dec << std::setfill(' ') << " signed=" << value << "\n";
}

static void trace64(const char* stage, const char* key, int64_t value, int path = -1, int step = -1, const char* pass = nullptr) {
    if (!g_pricing_trace) return;
    std::cout << "[NUM][" << stage << "]";
    if (pass) std::cout << " pass=" << pass;
    if (path >= 0) std::cout << " path=" << path;
    if (step >= 0) std::cout << " step=" << step;
    std::cout << " key=" << key
              << " value64=0x" << std::uppercase << std::hex << std::setw(16) << std::setfill('0')
              << static_cast<uint64_t>(value)
              << std::dec << std::setfill(' ') << " signed=" << value << "\n";
}

[[maybe_unused]] static double inverseNormalCDF(double p) {
    static const double a1 = -3.969683028665376e+01;
    static const double a2 =  2.209460984245205e+02;
    static const double a3 = -2.759285104469687e+02;
    static const double a4 =  1.383577518672690e+02;
    static const double a5 = -3.066479806614716e+01;
    static const double a6 =  2.506628277459239e+00;
    static const double b1 = -5.447609879822406e+01;
    static const double b2 =  1.615858368580409e+02;
    static const double b3 = -1.556989798598866e+02;
    static const double b4 =  6.680131188771972e+01;
    static const double b5 = -1.328068155288572e+01;
    static const double c1 = -7.784894002430293e-03;
    static const double c2 = -3.223964580411365e-01;
    static const double c3 = -2.400758277161838e+00;
    static const double c4 = -2.549732539343734e+00;
    static const double c5 =  4.374664141464968e+00;
    static const double c6 =  2.938163982698783e+00;
    static const double d1 =  7.784695709041462e-03;
    static const double d2 =  3.224671290700398e-01;
    static const double d3 =  2.445134137142996e+00;
    static const double d4 =  3.754408661907416e+00;
    const double plow = 0.02425;
    const double phigh = 1.0 - plow;
    double q, r;

    p = std::clamp(p, 1e-12, 1.0 - 1e-12);
    if (p < plow) {
        q = std::sqrt(-2.0 * std::log(p));
        return (((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) /
               ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0);
    }
    if (p > phigh) {
        q = std::sqrt(-2.0 * std::log(1.0 - p));
        return -(((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) /
                 ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0);
    }
    q = p - 0.5;
    r = q * q;
    return (((((a1*r + a2)*r + a3)*r + a4)*r + a5)*r + a6) * q /
           (((((b1*r + b2)*r + b3)*r + b4)*r + b5)*r + 1.0);
}

inline int32_t payoff(int32_t S, int32_t K, bool isPut) {
    if (isPut) return (K > S ? K - S : 0);
    return (S > K ? S - K : 0);
}

static bool solve3x3DoubleLocal(double aug[3][4], double beta[3]) {
    for (int pivot = 0; pivot < 3; ++pivot) {
        int best = pivot;
        double best_abs = std::fabs(aug[pivot][pivot]);
        for (int row = pivot + 1; row < 3; ++row) {
            double candidate = std::fabs(aug[row][pivot]);
            if (candidate > best_abs) {
                best_abs = candidate;
                best = row;
            }
        }
        if (best_abs < 1e-12) {
            return false;
        }
        if (best != pivot) {
            for (int col = pivot; col < 4; ++col) {
                std::swap(aug[pivot][col], aug[best][col]);
            }
        }

        double diag = aug[pivot][pivot];
        for (int col = pivot; col < 4; ++col) {
            aug[pivot][col] /= diag;
        }
        for (int row = pivot + 1; row < 3; ++row) {
            double factor = aug[row][pivot];
            if (std::fabs(factor) < 1e-15) {
                continue;
            }
            for (int col = pivot; col < 4; ++col) {
                aug[row][col] -= factor * aug[pivot][col];
            }
        }
    }

    for (int row = 2; row >= 0; --row) {
        double value = aug[row][3];
        for (int col = row + 1; col < 3; ++col) {
            value -= aug[row][col] * beta[col];
        }
        beta[row] = value;
    }
    return true;
}

static void solveRegression3x3Wide(const std::vector<int32_t>& X, const std::vector<int32_t>& Y, int32_t beta_out[3]) {
    int64_t s0 = 0;
    int64_t s1 = 0;
    int64_t s2 = 0;
    int64_t s3 = 0;
    int64_t s4 = 0;
    int64_t sy = 0;
    int64_t sxy = 0;
    int64_t sx2y = 0;

    for (std::size_t i = 0; i < X.size(); ++i) {
        int32_t x = X[i];
        int32_t y = Y[i];
        int32_t x2 = fxMul(x, x);
        int32_t x3 = fxMul(x2, x);
        int32_t x4 = fxMul(x2, x2);
        int32_t xy = fxMul(x, y);
        int32_t x2y = fxMul(x2, y);
        s0 += ONE;
        s1 += x;
        s2 += x2;
        s3 += x3;
        s4 += x4;
        sy += y;
        sxy += xy;
        sx2y += x2y;
    }

    if (s0 == 0) {
        beta_out[0] = 0;
        beta_out[1] = 0;
        beta_out[2] = 0;
        return;
    }

    const double q = static_cast<double>(ONE);
    const double mean_y = (static_cast<double>(sy) / q) / (static_cast<double>(s0) / q);
    double aug[3][4] = {
        {static_cast<double>(s0) / q, static_cast<double>(s1) / q, static_cast<double>(s2) / q, static_cast<double>(sy) / q},
        {static_cast<double>(s1) / q, static_cast<double>(s2) / q, static_cast<double>(s3) / q, static_cast<double>(sxy) / q},
        {static_cast<double>(s2) / q, static_cast<double>(s3) / q, static_cast<double>(s4) / q, static_cast<double>(sx2y) / q},
    };
    double beta_d[3] = {0.0, 0.0, 0.0};
    if (!solve3x3DoubleLocal(aug, beta_d)) {
        beta_d[0] = mean_y;
        beta_d[1] = 0.0;
        beta_d[2] = 0.0;
    } else {
        double max_abs_beta = std::max(std::fabs(beta_d[0]), std::max(std::fabs(beta_d[1]), std::fabs(beta_d[2])));
        if (max_abs_beta > REGRESSION_BETA_ABS_CAP) {
            beta_d[0] = mean_y;
            beta_d[1] = 0.0;
            beta_d[2] = 0.0;
        }
    }
    beta_out[0] = toint32_t(beta_d[0]);
    beta_out[1] = toint32_t(beta_d[1]);
    beta_out[2] = toint32_t(beta_d[2]);
}

void simulatePaths(int N, int M, int32_t S0, int32_t r, int32_t sigma, int32_t T, SobolGenerator& sobol, std::vector<Path>& outPaths) {
    int32_t M_q = toint32_t(static_cast<double>(M));
    int32_t dt = rtlFxDiv(T, M_q);
    int32_t half = toint32_t(0.5);
    int32_t sigma_sq = fxMul(sigma, sigma);
    int32_t half_sigma_sq = fxMul(half, sigma_sq);
    int32_t r_minus_half_sq = fxSub(r, half_sigma_sq);
    int32_t drift = fxMul(r_minus_half_sq, dt);
    int32_t sqrt_dt = rtlFxSqrt(dt);
    int32_t diff_coef = fxMul(sigma, sqrt_dt);
    trace32("INIT", "dt", dt);
    trace32("INIT", "drift_const", drift);
    trace32("INIT", "vol_sqrt_dt", diff_coef);

    for (int i = 0; i < N; ++i) {
        outPaths[i].S[0] = S0;
        std::vector<SobolSample> u = sobol.nextPointDetailed();
        for (int j = 1; j <= M; ++j) {
            int32_t Z = rtlInvCdfZs(u[j - 1].q16);
            trace32("PATH", "sobol_raw", static_cast<int32_t>(u[j - 1].raw), i, j);
            trace32("PATH", "u_q16", u[j - 1].q16, i, j);
            trace32("PATH", "z", Z, i, j);
            int32_t exponent = 0;
            int32_t exp_fixed = 0;
            outPaths[i].S[j] = rtlGbmStep(outPaths[i].S[j - 1], drift, diff_coef, Z, &exponent, &exp_fixed);
            trace32("PATH", "exp_arg", exponent, i, j);
            trace32("PATH", "exp", exp_fixed, i, j);
            trace32("PATH", "s_next", outPaths[i].S[j], i, j);
        }
    }
}

void backwardInduction(int N, int M, int32_t r, int32_t T, int32_t K, std::vector<Path>& paths, int32_t& price_out, bool isPut) {
    int32_t M_q = toint32_t(static_cast<double>(M));
    int32_t dt = fxDiv(T, M_q);
    int32_t neg_r = fxSub(toint32_t(0.0), r);
    int32_t arg0 = fxMul(neg_r, dt);
    int32_t discount = fxExp(arg0);
    std::vector<int32_t> immediate(N), continuation(N);

    for (int i = 0; i < N; i++) {
        paths[i].cashflow[M] = payoff(paths[i].S[M], K, isPut);
    }

    for (int j = M - 1; j > 0; --j) {
        std::vector<int> itm_indexes;
        itm_indexes.reserve(N);
        for (int i = 0; i < N; i++) {
            int32_t Sij = paths[i].S[j];
            immediate[i] = payoff(Sij, K, isPut);
            continuation[i] = fxMul(discount, paths[i].cashflow[j + 1]);
            if (immediate[i] > 0) itm_indexes.push_back(i);
        }

        if (!itm_indexes.empty()) {
            std::vector<int32_t> X, Y;
            X.reserve(itm_indexes.size());
            Y.reserve(itm_indexes.size());
            for (int idx : itm_indexes) {
                X.push_back(paths[idx].S[j]);
                Y.push_back(continuation[idx]);
            }
            int32_t beta[3];
            solveRegression3x3(X, Y, beta);

            for (int i = 0; i < N; ++i) {
                if (immediate[i] == 0) {
                    paths[i].cashflow[j] = continuation[i];
                } else {
                    int32_t Sij = paths[i].S[j];
                    int32_t term1 = fxMul(beta[1], Sij);
                    int32_t term2 = fxMul(beta[2], fxMul(Sij, Sij));
                    int32_t cont_est = fxAdd(fxAdd(beta[0], term1), term2);
                    paths[i].cashflow[j] = (immediate[i] >= cont_est) ? immediate[i] : continuation[i];
                }
            }
        } else {
            for (int i = 0; i < N; ++i) paths[i].cashflow[j] = continuation[i];
        }
    }

    int64_t sumPV = 0;
    for (int i = 0; i < N; ++i) {
        int exercise_t = M;
        for (int j = 1; j <= M; ++j) {
            int32_t pay = payoff(paths[i].S[j], K, isPut);
            if (pay > 0 && paths[i].cashflow[j] == pay) {
                exercise_t = j;
                break;
            }
        }
        int32_t tau = toint32_t(static_cast<double>(exercise_t));
        int32_t time_arg = fxMul(r, fxMul(tau, dt));
        int32_t df_tau = fxExp(fxSub(toint32_t(0.0), time_arg));
        int32_t pv_i = fxMul(paths[i].cashflow[exercise_t], df_tau);
        sumPV += static_cast<int64_t>(pv_i);
    }
    price_out = static_cast<int32_t>(sumPV / N);
}

void singleExerciseInduction(int N, int M, int32_t r, int32_t T, int32_t K, std::vector<Path>& paths, int32_t& price_out, bool isPut) {
    int32_t M_q = toint32_t(static_cast<double>(M));
    int32_t dt = rtlFxDiv(T, M_q);
    int32_t discount = rtlDiscount(r, dt);
    int32_t inv_K = rtlFxDiv(ONE, K);
    trace32("INIT", "disc", discount);
    trace32("INIT", "inv_K", inv_K);

    int32_t disc_total = ONE;
    for (int j = 0; j < M - 1; ++j) {
        disc_total = fxMul(disc_total, discount);
    }
    trace32("INIT", "disc_total", disc_total);

    std::vector<int32_t> X, Y;
    X.reserve(N);
    Y.reserve(N);
    std::vector<int32_t> continuation(N);
    int64_t sum1 = 0;
    int64_t sumx = 0;
    int64_t sumx2 = 0;
    int64_t sumx3 = 0;
    int64_t sumx4 = 0;
    int64_t sumy = 0;
    int64_t sumxy = 0;
    int64_t sumx2y = 0;

    int exercise_step = std::max(1, M - 1);
    for (int i = 0; i < N; ++i) {
        int32_t s_exercise = paths[i].S[exercise_step];
        int32_t s_terminal = paths[i].S[M];
        int32_t terminal_payoff = payoff(paths[i].S[M], K, isPut);
        continuation[i] = fxMul(discount, terminal_payoff);
        int32_t x_norm = fxMul(s_exercise, inv_K);
        int32_t x2 = fxMul(x_norm, x_norm);
        int32_t x3 = fxMul(x2, x_norm);
        int32_t x4 = fxMul(x2, x2);
        int32_t xy = fxMul(x_norm, continuation[i]);
        int32_t x2y = fxMul(x2, continuation[i]);
        X.push_back(x_norm);
        Y.push_back(continuation[i]);
        sum1 += ONE;
        sumx += x_norm;
        sumx2 += x2;
        sumx3 += x3;
        sumx4 += x4;
        sumy += continuation[i];
        sumxy += xy;
        sumx2y += x2y;
        trace32("ACC-IN", "s_exercise", s_exercise, i, exercise_step);
        trace32("ACC-IN", "s_terminal", s_terminal, i, M);
        trace32("ACC-IN", "terminal_payoff", terminal_payoff, i, M);
        trace32("ACC-IN", "cont_y", continuation[i], i, exercise_step);
        trace32("ACC-IN", "s_norm", x_norm, i, exercise_step);
    }
    trace64("ACC-SUM", "sum1", sum1);
    trace64("ACC-SUM", "sumx", sumx);
    trace64("ACC-SUM", "sumx2", sumx2);
    trace64("ACC-SUM", "sumx3", sumx3);
    trace64("ACC-SUM", "sumx4", sumx4);
    trace64("ACC-SUM", "sumy", sumy);
    trace64("ACC-SUM", "sumxy", sumxy);
    trace64("ACC-SUM", "sumx2y", sumx2y);
    trace32("ACC-MAT", "mat00", static_cast<int32_t>(sum1));
    trace32("ACC-MAT", "mat01", static_cast<int32_t>(sumx));
    trace32("ACC-MAT", "mat02", static_cast<int32_t>(sumx2));
    trace32("ACC-MAT", "mat03", static_cast<int32_t>(sumy));
    trace32("ACC-MAT", "mat10", static_cast<int32_t>(sumx));
    trace32("ACC-MAT", "mat11", static_cast<int32_t>(sumx2));
    trace32("ACC-MAT", "mat12", static_cast<int32_t>(sumx3));
    trace32("ACC-MAT", "mat13", static_cast<int32_t>(sumxy));
    trace32("ACC-MAT", "mat20", static_cast<int32_t>(sumx2));
    trace32("ACC-MAT", "mat21", static_cast<int32_t>(sumx3));
    trace32("ACC-MAT", "mat22", static_cast<int32_t>(sumx4));
    trace32("ACC-MAT", "mat23", static_cast<int32_t>(sumx2y));

    int32_t beta[3];
    solveRegression3x3Rtl(X, Y, beta);
    trace32("BETA", "beta0", beta[0]);
    trace32("BETA", "beta1", beta[1]);
    trace32("BETA", "beta2", beta[2]);

    int64_t sumPV = 0;
    for (int i = 0; i < N; ++i) {
        int32_t S_ex = paths[i].S[exercise_step];
        int32_t s_norm = fxMul(S_ex, inv_K);
        int32_t immediate = payoff(S_ex, K, isPut);
        int32_t s_norm_sq = fxMul(s_norm, s_norm);
        int32_t cont_est = fxAdd(fxAdd(beta[0], fxMul(beta[1], s_norm)), fxMul(beta[2], s_norm_sq));
        int32_t chosen = (immediate >= cont_est) ? immediate : continuation[i];
        int32_t discounted_pv = fxMul(chosen, disc_total);
        trace32("LSM", "immediate", immediate, i, exercise_step);
        trace32("LSM", "cont_est", cont_est, i, exercise_step);
        trace32("LSM", "chosen", chosen, i, exercise_step);
        trace32("PV", "discounted_pv", discounted_pv, i, exercise_step);
        sumPV += discounted_pv;
    }

    trace64("FINAL", "sum_pv", sumPV);
    price_out = static_cast<int32_t>(sumPV / N);
    trace32("FINAL", "price", price_out);
}

void multiExerciseInductionRtlMirror(int N, int M, int32_t r, int32_t T, int32_t K, std::vector<Path>& paths, int32_t& price_out, bool isPut) {
    int32_t M_q = toint32_t(static_cast<double>(M));
    int32_t dt = rtlFxDiv(T, M_q);
    int32_t discount = rtlDiscount(r, dt);
    int32_t inv_K = rtlFxDiv(ONE, K);
    const bool allowEarlyExercise = isPut;
    trace32("INIT", "disc", discount, -1, -1, "multi");
    trace32("INIT", "inv_K", inv_K, -1, -1, "multi");

    std::vector<int32_t> cashflow(N, 0);
    std::vector<int32_t> continuation(N, 0);
    std::vector<int32_t> immediate(N, 0);
    for (int i = 0; i < N; ++i) {
        cashflow[i] = payoff(paths[i].S[M], K, isPut);
        paths[i].cashflow[M] = cashflow[i];
        trace32("ACC-IN", "terminal_payoff", cashflow[i], i, M, "multi");
    }

    if (!allowEarlyExercise) {
        int32_t disc_total = ONE;
        for (int step = 0; step < M; ++step) {
            disc_total = fxMul(disc_total, discount);
        }
        trace32("INIT", "disc_total", disc_total, -1, -1, "multi");

        int64_t sumPV = 0;
        for (int i = 0; i < N; ++i) {
            int32_t discounted_pv = fxMul(disc_total, cashflow[i]);
            sumPV += discounted_pv;
            trace32("PV", "discounted_pv", discounted_pv, i, 0, "multi");
        }

        trace64("FINAL", "sum_pv", sumPV, -1, -1, "multi");
        price_out = static_cast<int32_t>(sumPV / N);
        trace32("FINAL", "price", price_out, -1, -1, "multi");
        return;
    }

    for (int step = M - 1; step >= 1; --step) {
        std::vector<int32_t> X;
        std::vector<int32_t> Y;
        X.reserve(N);
        Y.reserve(N);

        int64_t sum1 = 0;
        int64_t sumx = 0;
        int64_t sumx2 = 0;
        int64_t sumx3 = 0;
        int64_t sumx4 = 0;
        int64_t sumy = 0;
        int64_t sumxy = 0;
        int64_t sumx2y = 0;

        for (int i = 0; i < N; ++i) {
            continuation[i] = fxMul(discount, cashflow[i]);
            immediate[i] = payoff(paths[i].S[step], K, isPut);
            if (!allowEarlyExercise) {
                continue;
            }
            if (immediate[i] <= 0) {
                continue;
            }

            int32_t x_norm = fxMul(paths[i].S[step], inv_K);
            int32_t x_basis = fxSub(x_norm, ONE);
            int32_t x2 = fxMul(x_basis, x_basis);
            int32_t x3 = fxMul(x2, x_basis);
            int32_t x4 = fxMul(x2, x2);
            int32_t xy = fxMul(x_basis, continuation[i]);
            int32_t x2y = fxMul(x2, continuation[i]);
            X.push_back(x_basis);
            Y.push_back(continuation[i]);
            sum1 += ONE;
            sumx += x_basis;
            sumx2 += x2;
            sumx3 += x3;
            sumx4 += x4;
            sumy += continuation[i];
            sumxy += xy;
            sumx2y += x2y;
            trace32("ACC-IN", "immediate", immediate[i], i, step, "multi");
            trace32("ACC-IN", "cont_y", continuation[i], i, step, "multi");
            trace32("ACC-IN", "s_norm", x_norm, i, step, "multi");
            trace32("ACC-IN", "x_basis", x_basis, i, step, "multi");
        }

        trace64("ACC-SUM", "sum1", sum1, -1, step, "multi");
        trace64("ACC-SUM", "sumx", sumx, -1, step, "multi");
        trace64("ACC-SUM", "sumx2", sumx2, -1, step, "multi");
        trace64("ACC-SUM", "sumx3", sumx3, -1, step, "multi");
        trace64("ACC-SUM", "sumx4", sumx4, -1, step, "multi");
        trace64("ACC-SUM", "sumy", sumy, -1, step, "multi");
        trace64("ACC-SUM", "sumxy", sumxy, -1, step, "multi");
        trace64("ACC-SUM", "sumx2y", sumx2y, -1, step, "multi");

        int32_t beta[3] = {0, 0, 0};
        if (!X.empty()) {
            int32_t mean_y = rtlFxDiv(static_cast<int32_t>(sumy), static_cast<int32_t>(sum1));
            if (X.size() < 3) {
                beta[0] = mean_y;
            } else {
                solveRegression3x3Rtl(X, Y, beta);
                const int64_t beta_cap_q = static_cast<int64_t>(toint32_t(REGRESSION_BETA_ABS_CAP));
                const auto abs_raw = [](int32_t v) -> int64_t {
                    return v < 0 ? -static_cast<int64_t>(v) : static_cast<int64_t>(v);
                };
                if (abs_raw(beta[0]) > beta_cap_q ||
                    abs_raw(beta[1]) > beta_cap_q ||
                    abs_raw(beta[2]) > beta_cap_q) {
                    beta[0] = mean_y;
                    beta[1] = 0;
                    beta[2] = 0;
                }
            }
        }
        trace32("BETA", "beta0", beta[0], -1, step, "multi");
        trace32("BETA", "beta1", beta[1], -1, step, "multi");
        trace32("BETA", "beta2", beta[2], -1, step, "multi");

        for (int i = 0; i < N; ++i) {
            int32_t chosen = continuation[i];
            int32_t cont_est = continuation[i];
            if (allowEarlyExercise && immediate[i] > 0) {
                int32_t s_norm = fxMul(paths[i].S[step], inv_K);
                int32_t x_basis = fxSub(s_norm, ONE);
                int32_t x_basis_sq = fxMul(x_basis, x_basis);
                cont_est = fxAdd(fxAdd(beta[0], fxMul(beta[1], x_basis)), fxMul(beta[2], x_basis_sq));
                if (immediate[i] >= cont_est) {
                    chosen = immediate[i];
                }
            }
            cashflow[i] = chosen;
            paths[i].cashflow[step] = chosen;
            trace32("LSM", "immediate", immediate[i], i, step, "multi");
            trace32("LSM", "cont_est", cont_est, i, step, "multi");
            trace32("LSM", "chosen", chosen, i, step, "multi");
        }
    }

    int64_t sumPV = 0;
    for (int i = 0; i < N; ++i) {
        int32_t discounted_pv = fxMul(discount, cashflow[i]);
        sumPV += discounted_pv;
        trace32("PV", "discounted_pv", discounted_pv, i, 0, "multi");
    }

    trace64("FINAL", "sum_pv", sumPV, -1, -1, "multi");
    price_out = static_cast<int32_t>(sumPV / N);
    trace32("FINAL", "price", price_out, -1, -1, "multi");
}
