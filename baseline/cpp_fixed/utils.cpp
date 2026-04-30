#include "utils.h"
#include <fstream>
#include <iostream>
#include <string>
#include <unordered_map>

using namespace std;

bool parseArgs(int argc, char* argv[], int& N, int& M, double& S0, double& K, double& r, double& sigma, double& T, int& optionType, bool& fpgaStyle, bool& traceNumerical, string& directionFile, string& lutDirectory) {
    for (int i = 1; i < argc; ++i) {
        string arg = argv[i];
        if (arg == "--paths" && i + 1 < argc) N = stoi(argv[++i]);
        else if (arg == "--steps" && i + 1 < argc) M = stoi(argv[++i]);
        else if (arg == "--S0" && i + 1 < argc) S0 = stod(argv[++i]);
        else if (arg == "--K" && i + 1 < argc) K = stod(argv[++i]);
        else if (arg == "--r" && i + 1 < argc) r = stod(argv[++i]);
        else if (arg == "--sigma" && i + 1 < argc) sigma = stod(argv[++i]);
        else if (arg == "--T" && i + 1 < argc) T = stod(argv[++i]);
        else if ((arg == "--option-type" || arg == "--option_type") && i + 1 < argc) optionType = stoi(argv[++i]) & 1;
        else if (arg == "--put") optionType = 1;
        else if (arg == "--call") optionType = 0;
        else if (arg == "--fpga-style" || arg == "--single-exercise") fpgaStyle = true;
        else if (arg == "--full-lsm") fpgaStyle = false;
        else if (arg == "--trace-numerical" || arg == "--num-trace") traceNumerical = true;
        else if (arg == "--direction-file" && i + 1 < argc) directionFile = argv[++i];
        else if (arg == "--lut-dir" && i + 1 < argc) lutDirectory = argv[++i];
        else if (arg == "--input-file" && i + 1 < argc) {
            if (!loadParamsFromFile(argv[++i], N, M, S0, K, r, sigma, T, optionType, fpgaStyle, directionFile, lutDirectory)) {
                return false;
            }
        } else {
            cerr << "Unknown argument: " << arg << "\n";
            return false;
        }
    }
    return true;
}

bool loadParamsFromFile(const std::string& filePath,
                        int& N, int& M, double& S0, double& K, double& r, double& sigma, double& T,
                        int& optionType, bool& fpgaStyle, string& directionFile, string& lutDirectory) {
    ifstream in(filePath);
    if (!in.is_open()) {
        cerr << "Failed to open input file: " << filePath << "\n";
        return false;
    }

    unordered_map<string, double*> floatTargets{
        {"S0", &S0}, {"K", &K}, {"r", &r}, {"sigma", &sigma}, {"T", &T}
    };
    unordered_map<string, int*> intTargets{
        {"paths", &N}, {"steps", &M}, {"option_type", &optionType}, {"optionType", &optionType}
    };

    string line;
    while (getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto eqPos = line.find('=');
        if (eqPos == string::npos) continue;
        string key = line.substr(0, eqPos);
        string val = line.substr(eqPos + 1);
        if (intTargets.count(key)) {
            *intTargets[key] = stoi(val);
        } else if (floatTargets.count(key)) {
            *floatTargets[key] = stod(val);
        } else if (key == "pricing_mode") {
            fpgaStyle = (val != "full_lsm");
        } else if (key == "direction_file") {
            directionFile = val;
        } else if (key == "lut_dir") {
            lutDirectory = val;
        }
    }
    optionType &= 1;
    return true;
}
