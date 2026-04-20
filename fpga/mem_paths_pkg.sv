// Repo-root prefix for $readmemh paths (Vivado synth runs from runs/synth_1).
// For local sim / xvlog from repo root, leave REPO empty so paths stay "src/gen/...".
// Vivado build overwrites this file with an absolute REPO before synthesis.
package mem_paths_pkg;
    parameter string REPO = "";

    function automatic string join_path(input string rel);
        if (REPO == "")
            return rel;
        return {REPO, "/", rel};
    endfunction

    parameter string DIRECTION_MEM = join_path("src/gen/direction.mem");
    parameter string EXP_LUT      = join_path("src/gen/exp_lut_4096.mem");
    parameter string EXP_SIGNED    = join_path("src/gen/exp_signed_lut_8192.mem");
    parameter string LN_LUT       = join_path("src/gen/ln_lut_4096.mem");
    parameter string SQRT_LUT     = join_path("src/gen/sqrt_lut_256.mem");
endpackage
