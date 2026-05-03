#ifndef UTILS_H
#define UTILS_H

#include <chrono>
#include <string>

using Clock = std::chrono::high_resolution_clock;

enum class PricingMode {
    FpgaStyleSingle,
    FpgaStyleMulti,
    FullLsm
};

struct Timer {
    Clock::time_point start;
    void reset() { start = Clock::now(); }
    double elapsed() const { return std::chrono::duration<double>(Clock::now() - start).count(); }
};

bool parseArgs(int argc, char* argv[],
               int& N, int& M, double& S0, double& K, double& r, double& sigma, double& T,
               int& optionType, PricingMode& pricingMode, bool& traceNumerical,
               std::string& directionFile, std::string& lutDirectory);

bool loadParamsFromFile(const std::string& filePath,
                        int& N, int& M, double& S0, double& K, double& r, double& sigma, double& T,
                        int& optionType, PricingMode& pricingMode, std::string& directionFile, std::string& lutDirectory);

#endif
