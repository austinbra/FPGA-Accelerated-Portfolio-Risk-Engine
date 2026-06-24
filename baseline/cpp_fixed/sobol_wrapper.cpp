#include "sobol_wrapper.h"

#include <fstream>
#include <sstream>
#include <stdexcept>

namespace {

constexpr int SOBOL_WIDTH = 32;
constexpr int DEFAULT_DIMS = 50;

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

std::string resolveDirectionFile(const std::string& explicitPath) {
    if (!explicitPath.empty()) {
        if (canOpen(explicitPath)) return explicitPath;
        throw std::runtime_error("Failed to open direction file: " + explicitPath);
    }

    const char* name = "direction.mem";
    const std::string candidates[] = {
        name,
        joinPath("src/gen", name),
        joinPath("../src/gen", name),
        joinPath("../../src/gen", name),
        joinPath("../../../src/gen", name),
    };
    for (const std::string& candidate : candidates) {
        if (canOpen(candidate)) return candidate;
    }
    throw std::runtime_error("Could not locate RTL Sobol direction.mem");
}

std::vector<uint32_t> loadDirectionFile(const std::string& directionFile) {
    const std::string path = resolveDirectionFile(directionFile);
    std::ifstream in(path);
    if (!in.is_open()) {
        throw std::runtime_error("Failed to open direction file: " + path);
    }

    std::vector<uint32_t> values;
    values.reserve(DEFAULT_DIMS * SOBOL_WIDTH);
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
        values.push_back(raw);
    }
    if (values.empty()) {
        throw std::runtime_error("Direction file was empty: " + path);
    }
    return values;
}

} // namespace

SobolGenerator::SobolGenerator(int dimension, std::uint32_t skip, const std::string& directionFile)
    : dim_(dimension),
      skip_(skip),
      pointIndex_(0),
      direction_(loadDirectionFile(directionFile))
{
    if (dim_ <= 0) {
        throw std::runtime_error("Sobol dimension must be positive");
    }
    if (static_cast<std::size_t>(dim_ * SOBOL_WIDTH) > direction_.size()) {
        throw std::runtime_error("Direction file does not contain enough dimensions for requested steps");
    }
}

void SobolGenerator::reset(std::uint32_t skip) {
    skip_ = skip;
    pointIndex_ = 0;
}

uint32_t SobolGenerator::sobolRaw(uint32_t index, int dimension) const {
    if (dimension < 0 || dimension >= dim_) {
        throw std::runtime_error("Sobol dimension out of range");
    }

    const uint32_t gray = index ^ (index >> 1);
    uint32_t value = 0;
    for (int bit = 0; bit < SOBOL_WIDTH; ++bit) {
        if ((gray >> bit) & 1u) {
            value ^= direction_[static_cast<std::size_t>(dimension * SOBOL_WIDTH + bit)];
        }
    }
    return value;
}

int32_t SobolGenerator::q16FromRaw(uint32_t raw) {
    const uint32_t hi = raw >> FRAC_BITS;
    return static_cast<int32_t>(hi == 0 ? 1u : hi);
}

std::vector<SobolSample> SobolGenerator::nextPointDetailed() {
    const uint32_t rtlIndex = skip_ + pointIndex_ + 1u;
    ++pointIndex_;

    std::vector<SobolSample> result(dim_);
    for (int i = 0; i < dim_; ++i) {
        const uint32_t raw = sobolRaw(rtlIndex, i);
        const int32_t q16 = q16FromRaw(raw);
        result[i] = SobolSample{
            raw,
            q16,
            static_cast<Real>(q16) / static_cast<Real>(ONE)
        };
    }
    return result;
}

std::vector<Real> SobolGenerator::nextPoint() {
    const std::vector<SobolSample> detailed = nextPointDetailed();
    std::vector<Real> result(detailed.size());
    for (int i = 0; i < dim_; ++i) {
        result[i] = detailed[i].u;
    }
    return result;
}
