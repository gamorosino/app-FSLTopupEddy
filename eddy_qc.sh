#!/bin/bash
set -euo pipefail

mkdir -p qc/eddy_quad/work qc/eddy_quad/out regressors

BASE="qc/eddy_quad/work/eddy_corrected_data"

# Link final corrected DWI using original eddy basename
ln -sf ../../../dwi/dwi.nii.gz "${BASE}.nii.gz"

# Link eddy sidecars from raw
ln -sf ../../../raw/eddy_corrected_data.eddy_parameters "${BASE}.eddy_parameters"
ln -sf ../../../raw/eddy_corrected_data.eddy_movement_rms "${BASE}.eddy_movement_rms"
ln -sf ../../../raw/eddy_corrected_data.eddy_restricted_movement_rms "${BASE}.eddy_restricted_movement_rms"
ln -sf ../../../raw/eddy_corrected_data.eddy_outlier_map "${BASE}.eddy_outlier_map"
ln -sf ../../../raw/eddy_corrected_data.eddy_outlier_n_stdev_map "${BASE}.eddy_outlier_n_stdev_map"
ln -sf ../../../raw/eddy_corrected_data.eddy_outlier_n_sqr_stdev_map "${BASE}.eddy_outlier_n_sqr_stdev_map"
ln -sf ../../../raw/eddy_corrected_data.eddy_outlier_report "${BASE}.eddy_outlier_report"
ln -sf ../../../raw/eddy_corrected_data.eddy_rotated_bvecs "${BASE}.eddy_rotated_bvecs"

if [[ -f qc/eddy_quad/out/qc.pdf ]]; then
    echo "eddy_quad completed. skipping"
else
    eddy_quad "$BASE" \
        -idx raw/index.txt \
        -par raw/acq_params.txt \
        -m mask/mask.nii.gz \
        -b dwi/dwi.bvals \
        -g dwi/dwi.bvecs \
        -o qc/eddy_quad/out \
        -f raw/my_field.nii.gz
fi

echo "eddy QC complete: qc/eddy_quad/out"
