cmake_minimum_required(VERSION 3.20)

project(fpga_qmc_fixed_benchmarks LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(QMC_BENCHMARK_NATIVE_ARCH "Compile the benchmark for the host CPU" ON)

add_library(qmc_fixed_core STATIC
    pricing.cpp
    linalg.cpp
    rtl_math.cpp
    sobol_wrapper.cpp
)
target_include_directories(qmc_fixed_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

if(QMC_BENCHMARK_NATIVE_ARCH AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(qmc_fixed_core PRIVATE -march=native)
endif()

find_package(benchmark CONFIG QUIET)
if(NOT TARGET benchmark::benchmark)
    include(FetchContent)
    set(BENCHMARK_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
    set(BENCHMARK_ENABLE_GTEST_TESTS OFF CACHE BOOL "" FORCE)
    set(BENCHMARK_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(
        benchmark
        GIT_REPOSITORY https://github.com/google/benchmark.git
        GIT_TAG v1.9.4
        GIT_SHALLOW TRUE
    )
    FetchContent_MakeAvailable(benchmark)
endif()

add_executable(qmc_google_benchmark google_benchmark.cpp)
target_link_libraries(qmc_google_benchmark PRIVATE qmc_fixed_core benchmark::benchmark_main)
target_compile_definitions(
    qmc_google_benchmark
    PRIVATE QMC_BENCHMARK_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../src/gen"
)

if(QMC_BENCHMARK_NATIVE_ARCH AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(qmc_google_benchmark PRIVATE -march=native)
endif()
