#include "pricing.h"
#include "types.h"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {

bool checkFloor(bool isPut, int32_t spotAtValuation, int32_t terminalSpot) {
    constexpr int kPaths = 4;
    constexpr int kSteps = 1;
    const int32_t strike = toint32_t(100.0);
    const int32_t expectedIntrinsic = toint32_t(50.0);

    std::vector<Path> paths(kPaths, Path(kSteps));
    for (Path& path : paths) {
        path.S[0] = spotAtValuation;
        path.S[1] = terminalSpot;
    }

    int32_t price = 0;
    multiExerciseInductionRtlMirror(
        kPaths, kSteps, 0, ONE, strike, paths, price, isPut);

    if (price != expectedIntrinsic) {
        std::cerr << (isPut ? "PUT" : "CALL")
                  << " valuation-time floor failed: expected "
                  << expectedIntrinsic << ", got " << price << '\n';
        return false;
    }
    return true;
}

} // namespace

int main() {
    const bool putOk = checkFloor(
        true, toint32_t(50.0), toint32_t(75.0));
    const bool callOk = checkFloor(
        false, toint32_t(150.0), toint32_t(125.0));

    if (!putOk || !callOk) return 1;
    std::cout << "PASS: valuation-time intrinsic floor (PUT and CALL)\n";
    return 0;
}
