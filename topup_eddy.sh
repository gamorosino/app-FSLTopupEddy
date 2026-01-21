#!/bin/bash
set -euo pipefail
set -x

###############################################################################
# DWI distortion + motion/eddy correction using TOPUP + EDDY (eddy_openmp)
#
# Key fixes vs your original script:
#  1) TOPUP is estimated from opposite-PE b0 images AND is actually applied to
#     the full DWI series via eddy_openmp --topup=...
#  2) If epi1/epi2 are provided (separate b0 EPI images), they are used for TOPUP
#     instead of extracting b0 from diff/rdif. In that case rdif/rbvc/rbvl are
#     not required.
#  3) Diffusion metadata (PhaseEncodingDirection, TotalReadoutTime) is read from
#     embedded meta in config.json under ._inputs[].meta (id=="diff").
#  4) Optional "sstrip" creates a mask for TOPUP inputs (recommended) without
#     modifying epi1/epi2 images themselves.
#
# Requirements:
#  - FSL: topup, eddy_openmp, bet, fslmaths, fslmerge, fslinfo, select_dwi_vols
#  - jq
#
# Notes:
#  - This script assumes the config.json includes paths: diff,bvec,bval
#    and optionally rdif,rbvc,rbvl and/or epi1,epi2,epi1_json,epi2_json.
#  - If you set mergefull=true, you must also provide rdif/rbvc/rbvl (and ideally
#    rdif metadata embedded in config ._inputs[] with id=="rdif").
###############################################################################

export LD_LIBRARY_PATH=/pylon5/tr4s8pp/shayashi/cuda-8.0/lib64:${LD_LIBRARY_PATH:-}

CFG="config.json"
if [[ ! -f "$CFG" ]]; then
  echo "ERROR: config.json not found in current directory."
  exit 1
fi

# -----------------------
# Config: required paths
# -----------------------
diff=$(jq -r '.diff' "$CFG")
bvec=$(jq -r '.bvec' "$CFG")
bval=$(jq -r '.bval' "$CFG")

# Optional opposite-PE DWI (only needed if mergefull=true and you want to use it)
rdif=$(jq -r '.rdif // empty' "$CFG")
rbvc=$(jq -r '.rbvc // empty' "$CFG")
rbvl=$(jq -r '.rbvl // empty' "$CFG")

# Optional EPI b0 pair for topup
epi1=$(jq -r '.epi1 // empty' "$CFG")
epi2=$(jq -r '.epi2 // empty' "$CFG")
epi1_json=$(jq -r '.epi1_json // empty' "$CFG")
epi2_json=$(jq -r '.epi2_json // empty' "$CFG")

# Topup options (kept from your original style)
warpres=$(jq -r '.warpres // empty' "$CFG")
subsamp=$(jq -r '.subsamp // empty' "$CFG")
fwhm=$(jq -r '.fwhm // empty' "$CFG")
miter=$(jq -r '.miter // empty' "$CFG")
lambda=$(jq -r '.lambda // empty' "$CFG")
ssqlambda=$(jq -r '.ssqlambda // empty' "$CFG")
regmod=$(jq -r '.regmod // empty' "$CFG")
estmov=$(jq -r '.estmov // empty' "$CFG")
minmet=$(jq -r '.minmet // empty' "$CFG")
splineorder=$(jq -r '.splineorder // empty' "$CFG")
numprec=$(jq -r '.numprec // empty' "$CFG")
interp=$(jq -r '.interp // empty' "$CFG")
scale=$(jq -r '.scale // "false"' "$CFG")
regrid=$(jq -r '.regrid // "false"' "$CFG")

# Eddy options
refvol=$(jq -r '.refvol // 0' "$CFG")

# Behavior flags
reslice=$(jq -r '.reslice // "false"' "$CFG")
merge_full=$(jq -r '.mergefull // "false"' "$CFG")
sstrip=$(jq -r '.sstrip // "false"' "$CFG")

# -----------------------
# Helpers
# -----------------------
pe_to_vec() {
  case "$1" in
    i)  echo "1 0 0" ;;
    i-) echo "-1 0 0" ;;
    j)  echo "0 1 0" ;;
    j-) echo "0 -1 0" ;;
    k)  echo "0 0 1" ;;
    k-) echo "0 0 -1" ;;
    *)  echo "" ;;
  esac
}

get_meta_ped() {
  local id="$1"
  jq -r --arg ID "$id" '._inputs[] | select(.id==$ID) | .meta.PhaseEncodingDirection // empty' "$CFG"
}
get_meta_trt() {
  local id="$1"
  jq -r --arg ID "$id" '._inputs[] | select(.id==$ID) | .meta.TotalReadoutTime // empty' "$CFG"
}

get_pe_dir_file() { jq -r '.PhaseEncodingDirection // empty' "$1"; }
get_trt_file()    { jq -r '.TotalReadoutTime // empty' "$1"; }

bool_to_01() {
  if [[ "$1" == "true" ]]; then echo 1; else echo 0; fi
}

write_topup_config() {
  local cnf="$1"
  : > "$cnf"

  [[ -n "$warpres" ]]    && echo "--warpres=${warpres}" >> "$cnf"
  [[ -n "$subsamp" ]]    && echo "--subsamp=${subsamp}" >> "$cnf"
  [[ -n "$fwhm" ]]       && echo "--fwhm=${fwhm}" >> "$cnf"
  [[ -n "$miter" ]]      && echo "--miter=${miter}" >> "$cnf"
  [[ -n "$lambda" ]]     && echo "--lambda=${lambda}" >> "$cnf"
  [[ -n "$ssqlambda" ]]  && echo "--ssqlambda=${ssqlambda}" >> "$cnf"
  [[ -n "$regmod" ]]     && echo "--regmod=${regmod}" >> "$cnf"
  [[ -n "$estmov" ]]     && echo "--estmov=${estmov}" >> "$cnf"
  [[ -n "$minmet" ]]     && echo "--minmet=${minmet}" >> "$cnf"
  [[ -n "$splineorder" ]]&& echo "--splineorder=${splineorder}" >> "$cnf"
  [[ -n "$numprec" ]]    && echo "--numprec=${numprec}" >> "$cnf"
  [[ -n "$interp" ]]     && echo "--interp=${interp}" >> "$cnf"

  echo "--scale=${scale01}"  >> "$cnf"
  echo "--regrid=${regrid01}" >> "$cnf"
}


run_topup_cli() {
  # Try "new-style" topup CLI (some older builds will reject and print usage).
  topup --imain=b0_images.nii.gz \
        --datain=acq_params.txt \
        --out=my_topup_results \
        --fout=my_field \
        --iout=my_unwarped_images \
        $topup_mask_opt \
        --warpres="${warpres}" \
        --subsamp="${subsamp}" \
        --fwhm="${fwhm}" \
        --miter="${miter}" \
        --lambda="${lambda}" \
        --ssqlambda="${ssqlambda}" \
        --regmod="${regmod}" \
        --estmov="${estmov}" \
        --minmet="${minmet}" \
        --splineorder="${splineorder}" \
        --numprec="${numprec}" \
        --interp="${interp}" \
        --scale="${scale01}" \
        --regrid="${regrid01}" --verbose
}

run_topup_config() {
  local cnf="topup_config.cnf"
  write_topup_config "$cnf"
  topup --imain=b0_images.nii.gz \
        --datain=acq_params.txt \
        --config="$cnf" \
        --out=my_topup_results \
        --fout=my_field \
        --iout=my_unwarped_images \
        $topup_mask_opt --verbose
}

# -----------------------
# Sanity checks
# -----------------------
for f in "$diff" "$bvec" "$bval"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: required file missing: $f"
    exit 1
  fi
done

use_epi_topup=false
if [[ -n "$epi1" && -n "$epi2" ]]; then
  if [[ ! -f "$epi1" || ! -f "$epi2" ]]; then
    echo "ERROR: epi1/epi2 specified but files not found."
    exit 1
  fi
  if [[ -z "$epi1_json" || -z "$epi2_json" || ! -f "$epi1_json" || ! -f "$epi2_json" ]]; then
    echo "ERROR: epi1/epi2 specified but epi1_json/epi2_json missing or not found."
    exit 1
  fi
  use_epi_topup=true
fi

if [[ "$merge_full" == "true" ]]; then
  if [[ -z "$rdif" || -z "$rbvc" || -z "$rbvl" ]]; then
    echo "ERROR: mergefull=true but rdif/rbvc/rbvl are not provided in config.json."
    exit 1
  fi
  for f in "$rdif" "$rbvc" "$rbvl"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: required mergefull file missing: $f"
      exit 1
    fi
  done
fi

scale01=$(bool_to_01 "$scale")
regrid01=$(bool_to_01 "$regrid")

# -----------------------
# Folder structures
# -----------------------
mkdir -p dwi mask raw diff
if [[ "$merge_full" == "true" ]]; then
  mkdir -p rdif
fi

# -----------------------
# Copy inputs into working structure (unless reslice is true)
# -----------------------
if [[ "$reslice" == "false" ]]; then
  if [[ -f ./diff/dwi.nii.gz ]]; then
    echo "diff/dwi.nii.gz exists. skipping copying"
  else
    cp -v "$diff" ./diff/dwi.nii.gz
    cp -v "$bvec" ./diff/dwi.bvecs
    cp -v "$bval" ./diff/dwi.bvals
  fi

  if [[ "$merge_full" == "true" ]]; then
    if [[ -f ./rdif/dwi.nii.gz ]]; then
      echo "rdif/dwi.nii.gz exists. skipping copying"
    else
      cp -v "$rdif" ./rdif/dwi.nii.gz
      cp -v "$rbvc" ./rdif/dwi.bvecs
      cp -v "$rbvl" ./rdif/dwi.bvals
    fi
  fi
fi

# -----------------------
# Determine number of volumes
# -----------------------
diff_num=$(fslinfo ./diff/dwi.nii.gz | sed -n 5p | awk '{print $2}')
rdif_num=0
if [[ "$merge_full" == "true" ]]; then
  rdif_num=$(fslinfo ./rdif/dwi.nii.gz | sed -n 5p | awk '{print $2}')
fi

# -----------------------
# Build TOPUP b0 stack (b0_images.nii.gz) + acq_params.txt
# -----------------------
if [[ -f b0_images.nii.gz && -f acq_params.txt ]]; then
  echo "b0_images.nii.gz and acq_params.txt exist. skipping creation"
else
  if [[ "$use_epi_topup" == "true" ]]; then
    echo "Using epi1/epi2 for topup"

    diff_ped=$(get_meta_ped "diff")
    diff_trt=$(get_meta_trt "diff")
    if [[ -z "$diff_ped" || -z "$diff_trt" ]]; then
      echo "ERROR: diffusion PhaseEncodingDirection/TotalReadoutTime not found in embedded config meta (_inputs id==diff)."
      exit 1
    fi

    epi1_ped=$(get_pe_dir_file "$epi1_json")
    epi2_ped=$(get_pe_dir_file "$epi2_json")
    epi1_trt=$(get_trt_file "$epi1_json")
    epi2_trt=$(get_trt_file "$epi2_json")

    if [[ -z "$epi1_ped" || -z "$epi2_ped" || -z "$epi1_trt" || -z "$epi2_trt" ]]; then
      echo "ERROR: epi1_json/epi2_json missing PhaseEncodingDirection or TotalReadoutTime."
      exit 1
    fi

    if [[ "$epi1_ped" == "$diff_ped" ]]; then
      b0_a="$epi1"; json_a="$epi1_json"
      b0_b="$epi2"; json_b="$epi2_json"
    elif [[ "$epi2_ped" == "$diff_ped" ]]; then
      b0_a="$epi2"; json_a="$epi2_json"
      b0_b="$epi1"; json_b="$epi1_json"
    else
      echo "WARNING: Neither epi1 nor epi2 matches diffusion PhaseEncodingDirection ($diff_ped). Using epi1,epi2 order."
      b0_a="$epi1"; json_a="$epi1_json"
      b0_b="$epi2"; json_b="$epi2_json"
    fi

    [[ -f b0_images.nii.gz ]] || fslmerge -t b0_images.nii.gz "$b0_a" "$b0_b"

    vec_a=$(pe_to_vec "$(get_pe_dir_file "$json_a")")
    vec_b=$(pe_to_vec "$(get_pe_dir_file "$json_b")")
    trt_a=$(get_trt_file "$json_a")
    trt_b=$(get_trt_file "$json_b")

    if [[ -z "$vec_a" || -z "$vec_b" ]]; then
      echo "ERROR: Unsupported PhaseEncodingDirection in epi jsons."
      exit 1
    fi
    [[ -f acq_params.txt ]] || printf "%s %s\n%s %s\n" "$vec_a" "$trt_a" "$vec_b" "$trt_b" > acq_params.txt

  else
    echo "epi1/epi2 not provided; building topup inputs by extracting b0 from DWI(s)"

    if [[ "$merge_full" != "true" ]]; then
      echo "ERROR: No epi1/epi2 provided and mergefull!=true (no opposite-PE pair available for topup)."
      echo "Provide epi1/epi2 or provide rdif+mergefull=true."
      exit 1
    fi

    for PHASE in diff rdif; do
      if [[ ! -f ./${PHASE}/${PHASE}_nodif.nii.gz ]]; then
        select_dwi_vols ./${PHASE}/dwi.nii.gz ./${PHASE}/dwi.bvals ./${PHASE}/${PHASE}_nodif.nii.gz 0
      fi
      if [[ ! -f ./${PHASE}/${PHASE}_nodif_mean.nii.gz ]]; then
        fslmaths ./${PHASE}/${PHASE}_nodif -Tmean ./${PHASE}/${PHASE}_nodif_mean.nii.gz
      fi
    done

    [[ -f b0_images.nii.gz ]] || fslmerge -t b0_images.nii.gz ./diff/diff_nodif_mean.nii.gz ./rdif/rdif_nodif_mean.nii.gz

    diff_ped=$(get_meta_ped "diff"); diff_trt=$(get_meta_trt "diff")
    rdif_ped=$(get_meta_ped "rdif"); rdif_trt=$(get_meta_trt "rdif")

    if [[ -z "$diff_ped" || -z "$diff_trt" || -z "$rdif_ped" || -z "$rdif_trt" ]]; then
      echo "ERROR: rdif/diff embedded meta missing; cannot create acq_params robustly."
      echo "Add embedded meta for id==rdif or use epi1/epi2 inputs."
      exit 1
    fi

    vec_a=$(pe_to_vec "$diff_ped"); vec_b=$(pe_to_vec "$rdif_ped")
    if [[ -z "$vec_a" || -z "$vec_b" ]]; then
      echo "ERROR: Unsupported PhaseEncodingDirection in embedded meta."
      exit 1
    fi
    [[ -f acq_params.txt ]] || printf "%s %s\n%s %s\n" "$vec_a" "$diff_trt" "$vec_b" "$rdif_trt" > acq_params.txt
  fi
fi

# -----------------------
# Optional: mask for topup inputs (sstrip == true)
# -----------------------
topup_mask_opt=""
if [[ "$sstrip" == "true" ]]; then
  echo "sstrip=true: creating mask for topup inputs"
  if [[ ! -f b0_images_mean.nii.gz ]]; then
    fslmaths b0_images.nii.gz -Tmean b0_images_mean.nii.gz
  fi
  if [[ ! -f b0_images_mean_brain_mask.nii.gz ]]; then
    bet b0_images_mean.nii.gz b0_images_mean_brain.nii.gz -m -f 0.3
  fi
  topup_mask_opt="--mask=b0_images_mean_brain_mask.nii.gz"
fi



# -----------------------
# Sanity check
# -----------------------

# Validate topup inputs; rebuild if stale/invalid
if [[ ! -f b0_images.nii.gz ]]; then
  echo "ERROR: b0_images.nii.gz missing"
  exit 1
fi

dim4=$(fslinfo b0_images.nii.gz | awk '/^dim4/ {print $2}')
if [[ -z "${dim4:-}" ]]; then
  echo "ERROR: could not read dim4 from b0_images.nii.gz"
  exit 1
fi

if [[ "$dim4" -lt 2 ]]; then
  echo "ERROR: b0_images.nii.gz is not 4D with >=2 volumes (dim4=$dim4). Rebuilding."
  rm -f b0_images.nii.gz
  # force rebuild by deleting acq_params too
  rm -f acq_params.txt
fi

if [[ -f acq_params.txt ]]; then
  nrows=$(awk 'NF>0{c++} END{print c+0}' acq_params.txt)
  if [[ "$nrows" -ne "$dim4" ]]; then
    echo "ERROR: acq_params.txt rows ($nrows) != b0_images dim4 ($dim4). Rebuilding."
    rm -f b0_images.nii.gz acq_params.txt
  fi
fi


ls -lh b0_images.nii.gz acq_params.txt topup_config.cnf || true
fslinfo b0_images.nii.gz | egrep 'dim1|dim2|dim3|dim4'
cat acq_params.txt
head -n 5 topup_config.cnf || true
which topup

# -----------------------
# TOPUP (try CLI; if fails, fall back to --config)
# -----------------------
if [[ -f my_unwarped_images.nii.gz ]]; then
  echo "my_unwarped_images.nii.gz exists. skipping topup"
else
  set +e
  run_topup_cli
  topup_status=$?
  set -e

  if [[ $topup_status -ne 0 ]]; then
    echo "topup CLI-style options failed (status=$topup_status). Falling back to --config mode."
    run_topup_config
  fi
fi

# Average unwarped b0s + brain mask (used for eddy)
if [[ ! -f my_unwarped_images_avg.nii.gz ]]; then
  fslmaths my_unwarped_images.nii.gz -Tmean my_unwarped_images_avg.nii.gz
fi
if [[ ! -f my_unwarped_images_avg_brain_mask.nii.gz ]]; then
  bet my_unwarped_images_avg.nii.gz my_unwarped_images_avg_brain.nii.gz -m
fi

# -----------------------
# Build eddy input data (data.nii.gz), bvals, bvecs, index.txt
# -----------------------
if [[ -f data.nii.gz && -f bvals && -f bvecs && -f index.txt ]]; then
  echo "eddy inputs exist. skipping creation"
else
  if [[ "$merge_full" == "true" ]]; then
    echo "mergefull=true: merging diff + rdif for eddy"
    [[ -f data.nii.gz ]] || fslmerge -t data.nii.gz ./diff/dwi.nii.gz ./rdif/dwi.nii.gz
    [[ -f bvecs ]] || paste ./diff/dwi.bvecs ./rdif/dwi.bvecs > bvecs
    [[ -f bvals ]] || paste ./diff/dwi.bvals ./rdif/dwi.bvals > bvals

    if [[ ! -f index.txt ]]; then
      indx=""
      for ((i=0; i<diff_num; ++i)); do indx="${indx} 1"; done
      for ((i=0; i<rdif_num; ++i)); do indx="${indx} 2"; done
      echo "$indx" > index.txt
    fi
  else
    echo "mergefull=false: using diff only for eddy"
    [[ -f data.nii.gz ]] || cp ./diff/dwi.nii.gz data.nii.gz
    [[ -f bvecs ]] || cp ./diff/dwi.bvecs bvecs
    [[ -f bvals ]] || cp ./diff/dwi.bvals bvals

    if [[ ! -f index.txt ]]; then
      indx=""
      for ((i=0; i<diff_num; ++i)); do indx="${indx} 1"; done
      echo "$indx" > index.txt
    fi
  fi
fi

# -----------------------
# EDDY (applies TOPUP field to diffusion data)
# -----------------------
if [[ -f dwi/dwi.nii.gz ]]; then
  echo "Final dwi/dwi.nii.gz exists. skipping eddy"
else
  echo "Running eddy_openmp with --topup=my_topup_results (applies topup to DWIs)"

  # NOTE: removed --ref_scan because many builds don't support it; add back only if your eddy supports it.
  eddy_openmp \
    --imain=data.nii.gz \
    --mask=my_unwarped_images_avg_brain_mask.nii.gz \
    --acqp=acq_params.txt \
    --index=index.txt \
    --bvecs=bvecs \
    --bvals=bvals \
    --topup=my_topup_results \
    --out=eddy_corrected_data

  mv eddy_corrected_data.nii.gz dwi/dwi.nii.gz
  cp eddy_corrected_data.eddy_rotated_bvecs dwi/dwi.bvecs
  cp bvals dwi/dwi.bvals
fi

# -----------------------
# Mask output for downstream
# -----------------------
cp my_unwarped_images_avg_brain_mask.nii.gz mask/mask.nii.gz

# -----------------------
# Cleanup / archive intermediates
# -----------------------
mkdir -p raw
mv eddy_corrected_data.* raw/ 2>/dev/null || true
mv index.txt raw/ 2>/dev/null || true
mv data.nii.gz raw/ 2>/dev/null || true
mv bvals raw/ 2>/dev/null || true
mv bvecs raw/ 2>/dev/null || true
mv acq_params.txt raw/ 2>/dev/null || true
mv topup_config.cnf raw/ 2>/dev/null || true
mv b0_images*.nii.gz raw/ 2>/dev/null || true
mv b0_images_mean* raw/ 2>/dev/null || true
mv my_* raw/ 2>/dev/null || true
mv diff raw/ 2>/dev/null || true
mv rdif raw/ 2>/dev/null || true

echo "TOPUP+EDDY complete: dwi/dwi.nii.gz, dwi/dwi.bvecs, dwi/dwi.bvals, mask/mask.nii.gz"
