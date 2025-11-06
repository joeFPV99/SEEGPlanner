#!/usr/bin/env bash
# ================================================================
# Run nnUNet defacing on CTA, CT_PRE, CT_POST (skip MRI)
#
# Expected input structure per patient:
#   <ROOT>/<PATIENT>/{CTA,CT_PRE,CT_POST,MRI}/...
#
# Output structure per patient:
#   <ROOT>/<PATIENT>/defaced/CTA/...
#   <ROOT>/<PATIENT>/defaced/CT/...
#
# For each processed subfolder:
#   - Copy all *.nii.gz into a temp input dir with *_0000.nii.gz suffix
#   - Run: python run_CTA-DEFACE.py -i <temp_in> -o <final_out>
#
# Usage:
#   ./run_deface_ct_cta.sh <ROOT> [PYTHON_BIN] [DEFACER]
#     ROOT       : parent folder containing patient folders
#     PYTHON_BIN : (optional) python executable (default: python)
#     DEFACER    : (optional) path to run_CTA-DEFACE.py (default: run_CTA-DEFACE.py in PATH)
# ================================================================

set -euo pipefail

ROOT="${1:-}"
PYTHON_BIN="${2:-python}"
DEFACER="${3:-run_CTA-DEFACE.py}"

if [[ -z "$ROOT" ]]; then
  echo "Usage: $0 <ROOT> [PYTHON_BIN] [DEFACER]"
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Error: Python interpreter '$PYTHON_BIN' not found."
  exit 1
fi

# Allow DEFACER to be an absolute/relative file or on PATH
if ! command -v "$DEFACER" >/dev/null 2>&1; then
  if [[ ! -f "$DEFACER" ]]; then
    echo "Error: defacer script '$DEFACER' not found (not on PATH and not a file)."
    exit 1
  fi
fi

echo "========================================="
echo " nnUNet Defacing (CTA, CT_PRE, CT_POST)"
echo " Root         : $ROOT"
echo " Python       : $PYTHON_BIN"
echo " Defacer      : $DEFACER"
echo " File mode    : COPY (append _0000)"
echo "========================================="

shopt -s nullglob

# Helper: copy src to dst with _0000 suffix; resolves name collisions if needed.
copy_with_0000() {
  local src="$1" dst_dir="$2"
  local fname base target i
  fname="$(basename "$src")"
  base="${fname%.nii.gz}"
  if [[ "$base" =~ _0000$ ]]; then
    target="${base}.nii.gz"
  else
    target="${base}_0000.nii.gz"
  fi
  # avoid collisions
  if [[ -e "$dst_dir/$target" ]]; then
    i=1
    while [[ -e "$dst_dir/${base}_0000_$i.nii.gz" ]]; do
      i=$((i+1))
    done
    target="${base}_0000_$i.nii.gz"
  fi
  cp -f -- "$src" "$dst_dir/$target"
  echo "  prepared: $target"
}

process_modality() {
  local patient_dir="$1" modality="$2" out_bucket="$3"

  local in_dir="$patient_dir/$modality"
  [[ -d "$in_dir" ]] || return 0  # nothing to do

  # Temp per-modality input folder
  local tmp_in="$patient_dir/.deface_tmp/${modality}"
  mkdir -p "$tmp_in"

  local found=0
  for n in "$in_dir"/*.nii.gz; do
    [[ -e "$n" ]] || continue
    copy_with_0000 "$n" "$tmp_in"
    found=1
  done

  if [[ "$found" -eq 0 ]]; then
    echo " ↦ Skipping $modality: no NIfTI files found in $in_dir"
    rm -rf "$tmp_in"
    return 0
  fi

  # Final output dir: defaced/CTA or defaced/CT
  local final_out="$patient_dir/defaced/$out_bucket"
  mkdir -p "$final_out"

  echo "  >> Running deface: $modality  →  defaced/$out_bucket"
  "$PYTHON_BIN" "$DEFACER" -i "$tmp_in" -o "$final_out"
  echo "  >> Done: $modality"

  # Clean temp input
  rm -rf "$tmp_in"
}

# Iterate patients (immediate subdirs)
for patient_dir in "$ROOT"/*/; do
  [[ -d "$patient_dir" ]] || continue
  patient="$(basename "$patient_dir")"

  echo ""
  echo "=== Patient: $patient ==="

  # Run on CTA → defaced/CTA
  process_modality "$patient_dir" "CTA" "CTA"

  # Run on CT_PRE → defaced/CT
  process_modality "$patient_dir" "CT_PRE" "CT"

  # Run on CT_POST → defaced/CT
  process_modality "$patient_dir" "CT_POST" "CT"

  echo " * Completed patient: $patient * "
done

echo ""
echo "========================================="
echo " All defacing runs complete."
echo " Outputs saved under each patient's 'defaced/{CT,CTA}'"
echo "========================================="