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
#   ./dcm2nifti.sh <patients_root_dir> <output_dir>
#
# Dependencies:
#   - dcmdump (DCMTK)
#   - dcm2niix
# ================================================================

# Allow access to host binaries when running inside Flatpak VS Code
if [ -d /var/run/host/usr/bin ]; then
  export PATH="/var/run/host/usr/bin:/var/run/host/usr/local/bin:$PATH"
fi

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

# Arguments: ROOT folder containing PATxxx subfolders
INPUT_ROOT="${1:-}"
OUTPUT_ROOT="${2:-}"
if [[ -z "$INPUT_ROOT" || -z "$OUTPUT_ROOT" ]]; then
  echo "Usage: $0 <patients_root_dir> <output_dir>"
  exit 1
fi
if [[ ! -d "$INPUT_ROOT" ]]; then
  echo "Error: patients root directory not found: $INPUT_ROOT"
  exit 1
fi

echo "========================================="
echo " DICOM → NIfTI conversion (recursive, filtered)"
echo " Input parent : $INPUT_ROOT"
echo " Output root  : $OUTPUT_ROOT"
echo " Include only : CT; MR with 'T1' in SeriesDescription and Electrodes"
echo "========================================="

# Helper: choose the first file in a directory that is readable as DICOM for tags
# (recursive search). Writes chosen path to stdout; returns non-zero if none found.
pick_representative_file() {
  local dir="$1"
  local f
  while IFS= read -r -d '' f; do
    if dcmdump -q -M +P 0008,0060 "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "$dir" -type f ! -iname 'DICOMDIR' -size +0c -print0 2>/dev/null)
  return 1
}

# Ensure unique basename (adds _NNN if needed to avoid overwrite)
unique_basename() {
  local dir="$1" base="$2"
  if [[ ! -e "$dir/${base}.nii.gz" ]]; then
    printf '%s\n' "$base"; return
  fi
  local i=1 cand
  while :; do
    cand=$(printf "%s_%03d" "$base" "$i")
    [[ ! -e "$dir/${cand}.nii.gz" ]] && { printf '%s\n' "$cand"; return; }
    i=$((i+1))
  done
}

# Sanitize labels for safe filenames
sanitize_label() {
  local lbl="$*"
  #lbl="${lbl//\'/p}"
  #lbl="${lbl//´/p}"
  lbl="${lbl// /_}"
  lbl="${lbl//\//-}"
  lbl="${lbl//\\/-}"
  #keep: A-Z, a-z, 0-9, 
  lbl="${lbl//[^A-Za-z0-9._-]/_}"
  printf '%s' "$lbl"
}

shopt -s nullglob

# --------- LOOP OVER ALL PATIENTS UNDER INPUT_ROOT ----------
for INPUT_PATIENT_DIR in "$INPUT_ROOT"/*/; do
  [[ -d "$INPUT_PATIENT_DIR" ]] || continue

  patient_name="$(basename "$INPUT_PATIENT_DIR")"
  patient_out="$OUTPUT_ROOT/$patient_name"
  mkdir -p "$patient_out"

  echo ""
  echo ""
  echo "=== Patient: $patient_name ==="

  # Find all subdirectories recursively (exclude the patient root itself)
  mapfile -d '' subdirs < <(find "$INPUT_PATIENT_DIR" -type d -mindepth 1 -print0 2>/dev/null || true)

  for series_dir in "${subdirs[@]}"; do
    # Compute a RELATIVE path under the patient, in a portable way:
    rel_series_path="${series_dir#$INPUT_PATIENT_DIR}"
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

    # Read SeriesDescription (0008,103E) for MR and CT (CTA detection)
    series_desc=""
    if [[ "$modality" == "MR" || "$modality" == "CT" ]]; then
      series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
      series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
    fi

    # Decide conversion (only CT, MR with T1 ans SEG Electrodes)
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

  # --- SEG (Electrode Trajectories) handling — COPY DICOM, no NIfTI ---
  if [[ "$modality" == "SEG" ]]; then
    # Ensure SeriesDescription is available
    if [[ -z "${series_desc:-}" ]]; then
      series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
      series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
    fi

    # Any SeriesDescription that CONTAINS "Points and Trajectories" (case-insensitive)
    if echo "${series_desc:-}" | grep -qi "Points and Trajectories"; then
      echo ""
      echo "  Enter Subfolder: $rel_series_path  (Modality=$modality; SeriesDescription='${series_desc:-N/A}')"
      echo ""

      series_out_dir="$patient_out/Electrode_Trajectories"
      mkdir -p "$series_out_dir"

      # For every DICOM file in this SEG series (recursive)
      while IFS= read -r -d '' segf; do
        # SegmentLabel (0062,0005): try direct and then item[0] in SegmentSequence;
        # make dcmdump failures non-fatal.
        label="$(
          { dcmdump -q -M +P 0062,0005 "$segf" 2>/dev/null || true; } \
          | sed -n 's/.*\[\(.*\)\].*/\1/p'
        )"
        if [[ -z "$label" ]]; then
          label="$(
            { dcmdump -q -M +P '(0062,0002)[0].(0062,0005)' "$segf" 2>/dev/null || true; } \
            | sed -n 's/.*\[\(.*\)\].*/\1/p'
          )"
        fi
        [[ -z "$label" ]] && label="segment"

        safe_label="$(sanitize_label "$label")"
        base_name="electrode_${safe_label}"
        target="${series_out_dir}/${base_name}.dcm"

        # Avoid filename collisions: electrode_<label>.dcm, electrode_<label>_001.dcm, ...
        if [[ -e "$target" ]]; then
          i=1
          while [[ -e "${series_out_dir}/${base_name}_$(printf '%03d' "$i").dcm" ]]; do
            i=$((i+1))
          done
          target="${series_out_dir}/${base_name}_$(printf '%03d' "$i").dcm"
        fi

        cp -f -- "$segf" "$target" || {
          echo "  WARNING: failed to copy $segf" >&2
          continue
        }
        echo "  saved: $(basename "$target")"
      done < <(find "$series_dir" -type f ! -iname 'DICOMDIR' -size +0c -print0 2>/dev/null)

      # Done with this SEG series; proceed to next directory
      continue
    fi
  fi
  # --- END SEG handling ---

    if [[ "$convert" == "yes" ]]; then
      echo ""
      echo "  Enter Subfolder: $rel_series_path  (Modality=$modality; SeriesDescription='${series_desc:-N/A}')"
      echo ""

      # Normalized output directly under patient root
      # Default values (overridden per category below)
      series_out_dir="$patient_out"
      out_pattern="${patient_name}_${modality}"

      # Route CT vs CTA
      if [[ "$modality" == "CT" ]]; then
        # Ensure SeriesDescription available (for CTA + Pre/Post detection)
        if [[ -z "${series_desc:-}" ]]; then
          series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
          series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
        fi

        # CTA if SeriesDescription mentions CTA or Angio
        if echo "${series_desc:-}" | grep -Eqi "CTA|Angio"; then
          series_out_dir="$patient_out/CTA"
          out_pattern="${patient_name}_CTA"
        else
          # Not CTA → classify CT as Post vs Pre using 'post' in SeriesDescription
          if echo "${series_desc:-}" | grep -qi "post"; then
            series_out_dir="$patient_out/CT_Post"
            out_pattern="${patient_name}_CT_Post"
          else
            series_out_dir="$patient_out/CT_Pre"
            out_pattern="${patient_name}_CT_Pre"
          fi
        fi

        mkdir -p "$series_out_dir"
      fi

      # Route MRI T1
      if [[ "$modality" == "MR" ]]; then
        if echo "${series_desc:-}" | grep -qi "T1"; then
          series_out_dir="$patient_out/MRI_T1"
          out_pattern="${patient_name}_MRI_T1"
          mkdir -p "$series_out_dir"
        fi
      fi

      # Ensure unique filename if multiple series of same category exist
      out_pattern="$(unique_basename "$series_out_dir" "$out_pattern")"

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