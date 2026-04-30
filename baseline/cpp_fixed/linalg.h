#ifndef LINALG_H
#define LINALG_H

#include <vector>
#include "types.h"

void solveRegression3x3(const std::vector<int32_t>& X, const std::vector<int32_t>& Y, int32_t beta_out[3]);
void solveRegression3x3Rtl(const std::vector<int32_t>& X, const std::vector<int32_t>& Y, int32_t beta_out[3]);

#endif
