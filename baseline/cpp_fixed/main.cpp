#include "pricing.h"
#include "rtl_math.h"
#include "sobol_wrapper.h"
#include "types.h"
#include "utils.h"
#include <iostream>

int main(int argc, char *argv[])
{
    int N = N_DEFAULT;
    int M = M_DEFAULT;
    double S0_d = toDouble(S0_DEFAULT);
    double K_d = toDouble(K_DEFAULT);
    double r_d = toDouble(r_DEFAULT);
    double sigma_d = toDouble(sigma_DEFAULT);
    double T_d = toDouble(T_DEFAULT);
    int option_type = 1; // Default to PUT so early-exercise logic is financially meaningful.
    PricingMode pricing_mode = PricingMode::FpgaStyleSingle; // Current RTL parity oracle.
    bool trace_numerical = false;
    std::string direction_file;
    std::string lut_dir;

    if (!parseArgs(argc, argv, N, M, S0_d, K_d, r_d, sigma_d, T_d, option_type, pricing_mode, trace_numerical, direction_file, lut_dir))
    {
        std::cerr << "Invalid arguments.\n";
        std::cerr << "Usage:\n"
                  << "  --input-file <path> Parameter file (key=value lines)\n"
                  << "  --paths   <int>     Number of simulated paths (e.g., 1024)\n"
                  << "  --steps   <int>     Number of time steps (e.g., 12)\n"
                  << "  --S0      <float>   Spot price (e.g., 100.0)\n"
                  << "  --K       <float>   Strike price (e.g., 100.0)\n"
                  << "  --r       <float>   Risk-free rate (e.g., 0.05)\n"
                  << "  --sigma   <float>   Volatility (e.g., 0.2)\n"
                  << "  --T       <float>   Time to maturity in years (e.g., 1.0)\n"
                  << "  --option-type <0|1> 0=CALL, 1=PUT (default: 1)\n"
                  << "  --call / --put      Convenience aliases for option type\n"
                  << "  --fpga-style        Match current RTL single-exercise flow (default)\n"
                  << "  --exercise-mode <single|multi> Select FPGA-style exercise schedule\n"
                  << "  --multi-exercise    Convenience alias for --exercise-mode multi\n"
                  << "  --full-lsm          Run full backward-induction LSM baseline\n"
                  << "  --trace-numerical   Emit stage-by-stage raw Q16.16 trace\n"
                  << "  --direction-file <path> RTL Sobol direction.mem to mirror\n"
                  << "  --lut-dir <path>    Directory containing RTL fixed-point LUT .mem files\n";
        return 1;
    }

    int32_t S0_q = toint32_t(S0_d);
    int32_t K_q = toint32_t(K_d);
    int32_t r_q = toint32_t(r_d);
    int32_t sigma_q = toint32_t(sigma_d);
    int32_t T_q = toint32_t(T_d);

    Timer timer;
    timer.reset();
    setPricingTrace(trace_numerical);
    if (!lut_dir.empty()) {
        setRtlLutDirectory(lut_dir);
    }

    SobolGenerator sobol(M, 0, direction_file);
    std::vector<Path> paths(N, Path(M));
    simulatePaths(N, M, S0_q, r_q, sigma_q, T_q, sobol, paths);

    int32_t price_q;
    if (pricing_mode == PricingMode::FpgaStyleSingle) {
        singleExerciseInduction(N, M, r_q, T_q, K_q, paths, price_q, option_type != 0);
    } else if (pricing_mode == PricingMode::FpgaStyleMulti) {
        multiExerciseInductionRtlMirror(N, M, r_q, T_q, K_q, paths, price_q, option_type != 0);
    } else {
        backwardInduction(N, M, r_q, T_q, K_q, paths, price_q, option_type != 0);
    }

    double price_d = toDouble(price_q);
    double elapsed = timer.elapsed();
    const char* mode_label = "FULL_LSM";
    if (pricing_mode == PricingMode::FpgaStyleSingle) {
        mode_label = "FPGA_STYLE_SINGLE_EXERCISE";
    } else if (pricing_mode == PricingMode::FpgaStyleMulti) {
        mode_label = "FPGA_STYLE_MULTI_EXERCISE";
    }

    std::cout << "Option Type: " << ((option_type != 0) ? "PUT" : "CALL") << "\n";
    std::cout << "Pricing Mode: " << mode_label << "\n";
    std::cout << "Estimated Option Price (Q16.16): " << price_q << "\n";
    std::cout << "Estimated Option Price (double): " << price_d << "\n";
    std::cout << "Elapsed Time: " << elapsed << " seconds\n";
    return 0;
}
