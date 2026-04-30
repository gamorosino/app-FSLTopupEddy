#!/bin/bash
set -euo pipefail

mkdir -p qc/eddy_quad regressors

if [[ -d qc/eddy_quad/qc ]]; then
    echo "eddy_quad completed. skipping"
else
    echo "running eddy_quad"

    eddy_quad ./dwi/dwi \
        -idx ./raw/index.txt \
        -par ./raw/acq_params.txt \
        -m ./mask/mask.nii.gz \
        -b ./dwi/dwi.bvals \
        -g ./dwi/dwi.bvecs \
        -o ./qc/eddy_quad/qc \
        -f ./raw/my_field.nii.gz
fi

# Copy eddy motion/regressor files from raw into qc folder if needed
cp -n ./raw/eddy_corrected_data.eddy_parameters ./qc/eddy_quad/ 2>/dev/null || true
cp -n ./raw/eddy_corrected_data.eddy_movement_rms ./qc/eddy_quad/ 2>/dev/null || true
cp -n ./raw/eddy_corrected_data.eddy_restricted_movement_rms ./qc/eddy_quad/ 2>/dev/null || true

echo "eddy QC complete"
