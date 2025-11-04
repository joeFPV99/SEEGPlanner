#!/usr/bin/env bash
# ================================================================
# DICOM → NIfTI conversion (recursive, DCMTK-filtered)
#
# Rules:
#   - Enter every subfolder under each PATxxx patient directory (recursively).
#   - In each subfolder, take the FIRST file that is actually readable as DICOM.
#   - Read tags from that single file:
#       * Modality (0008,0060)
#       * SeriesDescription (0008,103E)
#   - Convert ONLY:
#       * CT series (Modality=CT), or
#       * MR series where SeriesDescription contains "T1" (case-insensitive)
#   - Convert the entire subfolder if it matches.
#   - Suppress JSON sidecars with dcm2niix (-b n).
#
# Usage:
#   ./dcm2nifti.sh <input_dicom_parent_dir> <output_dir>
#
# Dependencies:
#   - dcmdump (DCMTK)
#   - dcm2niix
# ================================================================

set -euo pipefail

# Verify tools
if ! command -v dcmdump >/dev/null 2>&1; then
  echo "Error: 'dcmdump' (DCMTK) not found. Please install DCMTK and ensure it's in your PATH."
  exit 1
fi
if ! command -v dcm2niix >/dev/null 2>&1; then
  echo "Error: 'dcm2niix' not found. Please install it (e.g., 'brew install dcm2niix')."
  exit 1
fi

# Arguments
INPUT_PARENT="${1:-}"
OUTPUT_ROOT="${2:-}"
if [[ -z "$INPUT_PARENT" || -z "$OUTPUT_ROOT" ]]; then
  echo "Usage: $0 <input_dicom_parent_dir> <output_dir>"
  exit 1
fi

echo "========================================="
echo " DICOM → NIfTI conversion (recursive, filtered)"
echo " Input parent : $INPUT_PARENT"
echo " Output root  : $OUTPUT_ROOT"
echo " Include only : CT; MR with 'T1' in SeriesDescription"
echo "========================================="

# Helper: choose the first file in a directory that is readable as DICOM for tags
# Writes chosen path to stdout; returns non-zero if none found.
pick_representative_file() {
  local dir="$1"
  # First pass: any regular file except obvious non-DICOM index files
  # Second pass: any regular file (last resort)
  # We only need one that lets 'dcmdump +P 0008,0060' succeed.
  local f
  while IFS= read -r -d '' f; do
    if dcmdump -q -M +P 0008,0060 "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f ! -iname 'DICOMDIR' -print0 2>/dev/null)

  while IFS= read -r -d '' f; do
    if dcmdump -q -M +P 0008,0060 "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)

  return 1
}

shopt -s nullglob

# Process each patient directory
for patient_dir in "$INPUT_PARENT"/PAT*/; do
  [[ -d "$patient_dir" ]] || continue
  patient_name="$(basename "$patient_dir")"


  echo ""
  echo ""
  echo "=== Patient: $patient_name ==="

  patient_out="$OUTPUT_ROOT/$patient_name"
  mkdir -p "$patient_out"

  # Find all subdirectories recursively (exclude the patient root itself)
  # We use -mindepth 1 so the patient_dir itself is not included.
  mapfile -d '' subdirs < <(find "$patient_dir" -type d -mindepth 1 -print0 2>/dev/null || true)

  # Iterate over each series directory candidate
  for series_dir in "${subdirs[@]}"; do
    # Compute a RELATIVE path under the patient, in a portable way:
    # remove the patient_dir prefix from series_dir
    rel_series_path="${series_dir#$patient_dir}"
    # Strip any leading slash (if present)
    rel_series_path="${rel_series_path#/}"

    # Pick a representative file that is actually readable as DICOM
    if ! rep_file="$(pick_representative_file "$series_dir")"; then
      echo ""
      echo " ↦ Skipping: $rel_series_path  (no readable DICOM file found)"
      continue
    fi

    # Read Modality (0008,0060)
    modality_line="$(dcmdump -M +P 0008,0060 "$rep_file" 2>/dev/null || true)"
    modality="$(echo "$modality_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"

    if [[ -z "$modality" ]]; then
      echo ""
      echo " ↦ Skipping: $rel_series_path  (Modality not found)"
      continue
    fi

    # Read SeriesDescription (0008,103E) for MR only
    series_desc=""
    if [[ "$modality" == "MR" ]]; then
      series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
      series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
    fi

    # Decide conversion
    convert="no"
    case "$modality" in
      CT)
        convert="yes"
        ;;
      MR)
        if echo "${series_desc:-}" | grep -qi "T1"; then
          convert="yes"
        fi
        ;;
    esac

    if [[ "$convert" == "yes" ]]; then
      echo ""
      echo "  Enter Subfolder: $rel_series_path  (Modality=$modality; SeriesDescription='${series_desc:-N/A}')"
      series_out_dir="$patient_out/$rel_series_path"
      echo ""
      mkdir -p "$series_out_dir"

      #set file name pattern for output -> PAT0xx_<Modality> 
      out_pattern="${patient_name}_${modality}"

      # If CT series appears to be CTA (SeriesDescription contains CTA/Angio), override destination and filename
      if [[ "$modality" == "CT" ]]; then
        if [[ -z "${series_desc:-}" ]]; then
          series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
          series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
        fi
        if echo "${series_desc:-}" | grep -Eqi "CTA|Angio"; then
          series_out_dir="$patient_out/CTA"
          out_pattern="${patient_name}_CTA"
          mkdir -p "$series_out_dir"
        fi
      fi

      # Run conversion silently: suppress all dcm2niix warnings/errors
      dcm2niix -b n -z y -f "$out_pattern" -o "$series_out_dir" "$series_dir" 2>/dev/null

    else
      echo ""
      echo " ↦ Skipping:   $rel_series_path  (Modality=$modality; SeriesDescription='${series_desc:-N/A}')"
    fi
  done

  echo ""
  echo " * Completed patient: $patient_name * "
done

echo ""
echo "========================================="
echo " All conversions complete."
echo " NIfTI files saved under: $OUTPUT_ROOT"
echo "========================================="