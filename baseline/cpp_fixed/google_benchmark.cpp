#include <benchmark/benchmark.h>

#include "pricing.h"
#include "rtl_math.h"
#include "sobol_wrapper.h"
#include "types.h"

#include <cstdint>
#include <string>
#include <vector>

namespace {

constexpr int kPaths = 1024;
constexpr int kSteps = 12;
constexpr int32_t kExpectedPrice = 428757;

const int32_t kS0 = toint32_t(100.0);
const int32_t kStrike = toint32_t(100.0);
const int32_t kRate = toint32_t(0.05);
const int32_t kVolatility = toint32_t(0.2);
const int32_t kMaturity = toint32_t(1.0);

const std::string kDataDirectory = QMC_BENCHMARK_DATA_DIR;
const std::string kDirectionFile = kDataDirectory + "/direction.mem";

void prepareRtlTables() {
    setPricingTrace(false);
    setRtlLutDirectory(kDataDirectory);

    // LUT file I/O is a one-time process initialization cost, not part of a
    // pricing request. Force it to happen before either timed loop.
    benchmark::DoNotOptimize(rtlFxLnLut(ONE));
    benchmark::DoNotOptimize(rtlFxExpLutUnsigned(0));
    benchmark::DoNotOptimize(rtlFxExpLutSigned(0));
}

std::vector<Path> generatePaths() {
    SobolGenerator sobol(kSteps, 0, kDirectionFile);
    std::vector<Path> paths(kPaths, Path(kSteps));
    simulatePaths(
        kPaths, kSteps, kS0, kRate, kVolatility, kMaturity, sobol, paths);
    return paths;
}

void verifyPrice(benchmark::State& state, int32_t price) {
    if (price != kExpectedPrice) {
        const std::string message =
            "bit-exact price mismatch: expected " +
            std::to_string(kExpectedPrice) + ", got " +
            std::to_string(price);
        state.SkipWithError(message.c_str());
    }
}

void finishCounters(benchmark::State& state) {
    state.SetItemsProcessed(state.iterations() * kPaths);
    state.SetLabel("Q16.16 price=428757");
}

int32_t expectedMatrixPrice(int paths, int steps) {
    if (paths == 64 && steps == 4) return 426130;
    if (paths == 64 && steps == 12) return 373676;
    if (paths == 64 && steps == 24) return 356530;
    if (paths == 64 && steps == 50) return 389580;
    if (paths == 256 && steps == 4) return 395487;
    if (paths == 256 && steps == 12) return 426642;
    if (paths == 256 && steps == 24) return 384128;
    if (paths == 256 && steps == 50) return 385641;
    if (paths == 1024 && steps == 4) return 391343;
    if (paths == 1024 && steps == 12) return 428757;
    if (paths == 1024 && steps == 24) return 408031;
    if (paths == 1024 && steps == 50) return 396582;
    return 0;
}

// Matches the old std::chrono boundary after one-time LUT initialization:
// Sobol direction-file loading, path allocation, path simulation, and
// multi-date backward induction all run inside every measured iteration.
void BM_EndToEndMultiPut(benchmark::State& state) {
    prepareRtlTables();

    int32_t price = 0;
    for (auto _ : state) {
        SobolGenerator sobol(kSteps, 0, kDirectionFile);
        std::vector<Path> paths(kPaths, Path(kSteps));
        simulatePaths(
            kPaths, kSteps, kS0, kRate, kVolatility, kMaturity, sobol, paths);
        multiExerciseInductionRtlMirror(
            kPaths, kSteps, kRate, kMaturity, kStrike, paths, price, true);
        benchmark::DoNotOptimize(price);
    }

    verifyPrice(state, price);
    finishCounters(state);
}
BENCHMARK(BM_EndToEndMultiPut)->Unit(benchmark::kMillisecond);

// Measures repeated repricing when the deterministic Sobol/GBM paths have
// already been generated. The induction routine's working allocations remain
// inside the measured loop.
void BM_MultiDateInductionOnly(benchmark::State& state) {
    prepareRtlTables();
    std::vector<Path> paths = generatePaths();

    int32_t price = 0;
    for (auto _ : state) {
        multiExerciseInductionRtlMirror(
            kPaths, kSteps, kRate, kMaturity, kStrike, paths, price, true);
        benchmark::DoNotOptimize(price);
        benchmark::ClobberMemory();
    }

    verifyPrice(state, price);
    finishCounters(state);
}
BENCHMARK(BM_MultiDateInductionOnly)->Unit(benchmark::kMillisecond);

// Apples-to-apples scaling sweep: every timed iteration includes the same
// direction-file load, path allocation/generation, and multi-date induction.
void BM_EndToEndMultiPutMatrix(benchmark::State& state) {
    prepareRtlTables();
    const int paths = static_cast<int>(state.range(0));
    const int steps = static_cast<int>(state.range(1));

    int32_t price = 0;
    for (auto _ : state) {
        SobolGenerator sobol(steps, 0, kDirectionFile);
        std::vector<Path> generated(paths, Path(steps));
        simulatePaths(
            paths, steps, kS0, kRate, kVolatility, kMaturity, sobol, generated);
        multiExerciseInductionRtlMirror(
            paths, steps, kRate, kMaturity, kStrike, generated, price, true);
        benchmark::DoNotOptimize(price);
    }

    const int32_t expected = expectedMatrixPrice(paths, steps);
    if (price != expected) {
        const std::string message =
            "matrix price mismatch: expected " + std::to_string(expected) +
            ", got " + std::to_string(price);
        state.SkipWithError(message.c_str());
    }
    state.SetItemsProcessed(state.iterations() * paths);
    state.SetLabel("Q16.16 price=" + std::to_string(price));
}

BENCHMARK(BM_EndToEndMultiPutMatrix)
    ->ArgsProduct({{64, 256, 1024}, {4, 12, 24, 50}})
    ->Unit(benchmark::kMillisecond);

// Closest comparison to the persistent FPGA kernel: Sobol direction data and
// fixed LUTs are initialized once, while path allocation, path generation, and
// LSM induction remain inside every measured pricing request.
void BM_PricingCoreMultiPutMatrix(benchmark::State& state) {
    prepareRtlTables();
    const int paths = static_cast<int>(state.range(0));
    const int steps = static_cast<int>(state.range(1));
    SobolGenerator sobol(steps, 0, kDirectionFile);

    int32_t price = 0;
    for (auto _ : state) {
        sobol.reset();
        std::vector<Path> generated(paths, Path(steps));
        simulatePaths(
            paths, steps, kS0, kRate, kVolatility, kMaturity, sobol, generated);
        multiExerciseInductionRtlMirror(
            paths, steps, kRate, kMaturity, kStrike, generated, price, true);
        benchmark::DoNotOptimize(price);
    }

    const int32_t expected = expectedMatrixPrice(paths, steps);
    if (price != expected) {
        const std::string message =
            "core matrix price mismatch: expected " + std::to_string(expected) +
            ", got " + std::to_string(price);
        state.SkipWithError(message.c_str());
    }
    state.SetItemsProcessed(state.iterations() * paths);
    state.SetLabel("Q16.16 price=" + std::to_string(price));
}

BENCHMARK(BM_PricingCoreMultiPutMatrix)
    ->ArgsProduct({{64, 256, 1024}, {4, 12, 24, 50}})
    ->Unit(benchmark::kMillisecond);

// Strict hot-kernel comparison: deterministic direction data and the path
// storage are persistent, matching the FPGA's preallocated BRAM. The timed
// region still performs all Sobol/GBM generation and LSM backward induction.
// Temporary vectors internal to the reference algorithm remain timed because
// they are part of the C++ implementation being compared.
void BM_HotKernelMultiPutMatrix(benchmark::State& state) {
    prepareRtlTables();
    const int paths = static_cast<int>(state.range(0));
    const int steps = static_cast<int>(state.range(1));
    SobolGenerator sobol(steps, 0, kDirectionFile);
    std::vector<Path> generated(paths, Path(steps));

    int32_t price = 0;
    for (auto _ : state) {
        sobol.reset();
        simulatePaths(
            paths, steps, kS0, kRate, kVolatility, kMaturity, sobol, generated);
        multiExerciseInductionRtlMirror(
            paths, steps, kRate, kMaturity, kStrike, generated, price, true);
        benchmark::DoNotOptimize(price);
        benchmark::ClobberMemory();
    }

    const int32_t expected = expectedMatrixPrice(paths, steps);
    if (price != expected) {
        const std::string message =
            "hot-kernel matrix price mismatch: expected " +
            std::to_string(expected) + ", got " + std::to_string(price);
        state.SkipWithError(message.c_str());
    }
    state.SetItemsProcessed(state.iterations() * paths);
    state.SetLabel("Q16.16 price=" + std::to_string(price));
}

BENCHMARK(BM_HotKernelMultiPutMatrix)
    ->ArgsProduct({{64, 256, 1024}, {4, 12, 24, 50}})
    ->Unit(benchmark::kMillisecond);

void BM_PricingCoreSinglePut1024x12(benchmark::State& state) {
    prepareRtlTables();
    SobolGenerator sobol(kSteps, 0, kDirectionFile);

    int32_t price = 0;
    for (auto _ : state) {
        sobol.reset();
        std::vector<Path> generated(kPaths, Path(kSteps));
        simulatePaths(
            kPaths, kSteps, kS0, kRate, kVolatility, kMaturity, sobol, generated);
        singleExerciseInduction(
            kPaths, kSteps, kRate, kMaturity, kStrike, generated, price, true);
        benchmark::DoNotOptimize(price);
    }

    if (price != 360645) {
        const std::string message =
            "single-date price mismatch: expected 360645, got " +
            std::to_string(price);
        state.SkipWithError(message.c_str());
    }
    state.SetItemsProcessed(state.iterations() * kPaths);
    state.SetLabel("Q16.16 price=360645");
}
BENCHMARK(BM_PricingCoreSinglePut1024x12)->Unit(benchmark::kMillisecond);

}  // namespace
