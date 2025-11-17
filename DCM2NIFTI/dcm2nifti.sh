#!/usr/bin/env bash
# ================================================================
# DICOM → NIfTI conversion (recursive, DCMTK-filtered)
#
# High-level behavior:
#   - INPUT_ROOT contains multiple patient folders (e.g. PAT001, PAT002, ...).
#   - For each patient folder:
#       - Recursively scan all subdirectories (series candidates).
#       - In each subdirectory, pick ONE representative DICOM file.
#       - Read:
#           * Modality (0008,0060)
#           * SeriesDescription (0008,103E)
#       - Convert to NIfTI ONLY:
#           * CT series      (Modality=CT) → CT_Pre / CT_Post / CTA
#           * MRI T1 series  (Modality=MR, SeriesDescription contains "T1")
#       - Handle SEG series:
#           * Modality=SEG AND SeriesDescription contains "Points and Trajectories"
#           * Copy all SEG DICOMs into Electrode_Trajectories as electrode_<label>.dcm
#       - Suppress JSON sidecars from dcm2niix (-b n).
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

# Strict error handling:
#   -e : exit on first command failure
#   -u : error on use of unset variables
#   -o pipefail : pipeline fails if any component fails
set -euo pipefail

# Verify tools are available in PATH
if ! command -v dcmdump >/dev/null 2>&1; then
  echo "Error: 'dcmdump' (DCMTK) not found. Please install DCMTK and ensure it's in your PATH."
  exit 1
fi
if ! command -v dcm2niix >/dev/null 2>&1; then
  echo "Error: 'dcm2niix' not found. Please install it (e.g., 'brew install dcm2niix')."
  exit 1
fi

# Arguments: ROOT folder containing multiple patient subfolders (PATxxx)
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

# ----------------------------------------------------------------
# Helper: choose the first file in a directory that is readable as DICOM
# Behavior:
#   - Only check files directly inside the given directory (maxdepth 1).
#   - Ignore DICOMDIR and zero-byte files.
#   - As soon as a file where dcmdump can read Modality (0008,0060) is found,
#     print its path and return success.
#   - If no suitable file is found, return non-zero.
# ----------------------------------------------------------------
pick_representative_file() {
  local dir="$1"
  local f

  # Only look at files directly in THIS directory (leaf series)
  # - e.g.:
  #   - PATxxx/CT Caput/CT_scan/ → CT slices → Modality=CT
  #   - PATxxx/CT Caput/Points & Traj A/ → SEG files → Modality=SEG
  #   - Directories with no files at this level will be skipped.
  while IFS= read -r -d '' f; do
    if dcmdump -q -M +P 0008,0060 "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f ! -iname 'DICOMDIR' -size +0c -print0 2>/dev/null)

  # No readable DICOM directly in this folder
  return 1
}

# ----------------------------------------------------------------
# Helper: ensure a unique NIfTI basename inside a directory.
#   - If <base>.nii.gz does not exist → use <base>.
#   - Otherwise append _NNN (001, 002, ...) until a free basename is found.
# ----------------------------------------------------------------
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

# ----------------------------------------------------------------
# Helper: sanitize a label string so it is safe as a filename.
# Behavior:
#   - Replace spaces with underscores.
#   - Replace / and \ with -.
#   - Replace all characters not in [A-Za-z0-9._-] with underscores.
# ----------------------------------------------------------------
sanitize_label() {
  local lbl="$*"
  #lbl="${lbl//\'/p}"
  #lbl="${lbl//´/p}"
  lbl="${lbl// /_}"
  lbl="${lbl//\//-}"
  lbl="${lbl//\\/-}"
  # keep: A-Z, a-z, 0-9, dot, underscore, dash
  lbl="${lbl//[^A-Za-z0-9._-]/_}"
  printf '%s' "$lbl"
}

shopt -s nullglob

# ----------------------------------------------------------------
# LOOP OVER ALL PATIENTS UNDER INPUT_ROOT
#   - Each immediate subdirectory of INPUT_ROOT is treated as one patient.
# ----------------------------------------------------------------
for INPUT_PATIENT_DIR in "$INPUT_ROOT"/*/; do
  [[ -d "$INPUT_PATIENT_DIR" ]] || continue

  patient_name="$(basename "$INPUT_PATIENT_DIR")"
  patient_out="$OUTPUT_ROOT/$patient_name"
  mkdir -p "$patient_out"

  echo ""
  echo ""
  echo "=== Patient: $patient_name ==="

  # Find all subdirectories recursively (exclude the patient root itself
  # and our own Electrode_Trajectories output folder).
  mapfile -d '' subdirs < <(find "$INPUT_PATIENT_DIR" -type d -mindepth 1 ! -name 'Electrode_Trajectories' -print0 2>/dev/null || true)

  # ----------------------------------------------------------------
  # Iterate over each subdirectory as a candidate DICOM series folder.
  # ----------------------------------------------------------------
  for series_dir in "${subdirs[@]}"; do
    # Compute a RELATIVE path under the patient:
    rel_series_path="${series_dir#$INPUT_PATIENT_DIR}"
    rel_series_path="${rel_series_path#/}"

    # Pick a representative file that is actually readable as DICOM
    if ! rep_file="$(pick_representative_file "$series_dir")"; then
      echo ""
      echo " ↦ Skipping: $rel_series_path  (no readable DICOM file found)"
      continue
    fi

    # Read Modality (0008,0060) from representative DICOM
    modality_line="$(dcmdump -M +P 0008,0060 "$rep_file" 2>/dev/null || true)"
    modality="$(echo "$modality_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"

    if [[ -z "$modality" ]]; then
      echo ""
      echo " ↦ Skipping: $rel_series_path  (Modality not found)"
      continue
    fi

    # Read SeriesDescription (0008,103E) for MR and CT (used for T1 / CTA / Pre/Post)
    series_desc=""
    if [[ "$modality" == "MR" || "$modality" == "CT" ]]; then
      series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
      series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
    fi

    # Decide conversion for dcm2niix:
    #   - CT → always convert (later split into CTA / CT_Pre / CT_Post).
    #   - MR → only convert if SeriesDescription contains "T1".
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

    # --------------------------------------------------------------
    # SEG (Electrode Trajectories) handling — COPY DICOM, no NIfTI
    #   - Trigger if Modality=SEG.
    #   - Require SeriesDescription containing "Points and Trajectories".
    #   - Copy all SEG DICOMs in this folder as electrode_<label>.dcm.
    #   - Output: PATxxx/Electrode_Trajectories/
    #   - Skip NIfTI conversion for these series.
    # --------------------------------------------------------------
    if [[ "$modality" == "SEG" ]]; then
      # Ensure SeriesDescription is available for SEG, too
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
          # Try to get SegmentLabel (0062,0005) in two ways:
          #   - direct 0062,0005
          #   - '(0062,0002)[0].(0062,0005)' (SegmentSequence item 0)
          # dcmdump failures are made non-fatal with "|| true".
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

          # Avoid filename collisions:
          #   electrode_<label>.dcm
          #   electrode_<label>_001.dcm
          #   electrode_<label>_002.dcm
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

        # Done with this SEG series; proceed directly to next directory
        continue
      fi
    fi
    # ---------------------- END SEG handling ----------------------

    # --------------------------------------------------------------
    # NIfTI CONVERSION BLOCK (CT / CTA / CT_Pre / CT_Post / MRI_T1)
    # --------------------------------------------------------------
    if [[ "$convert" == "yes" ]]; then
      echo ""
      echo "  Enter Subfolder: $rel_series_path  (Modality=$modality; SeriesDescription='${series_desc:-N/A}')"
      echo ""

      # Default output location (overridden per category below)
      series_out_dir="$patient_out"
      out_pattern="${patient_name}_${modality}"

      # Prepare a safe label from SeriesDescription for filenames
      # (use "NoLabel" if SeriesDescription is empty)
      label_for_name="${series_desc:-NoLabel}"
      label_for_name="$(sanitize_label "$label_for_name")"

      # Route CT vs CTA and CT_Pre/CT_Post, and include label in name
      if [[ "$modality" == "CT" ]]; then
        # Ensure SeriesDescription available (for CTA + Pre/Post detection)
        if [[ -z "${series_desc:-}" ]]; then
          series_desc_line="$(dcmdump -M +P 0008,103E "$rep_file" 2>/dev/null || true)"
          series_desc="$(echo "$series_desc_line" | sed -n 's/.*\[\(.*\)\].*/\1/p')"
          label_for_name="${series_desc:-NoLabel}"
          label_for_name="$(sanitize_label "$label_for_name")"
        fi

        # CTA if SeriesDescription mentions CTA or Angio
        if echo "${series_desc:-}" | grep -Eqi "CTA|Angio"; then
          series_out_dir="$patient_out/CTA"
          out_pattern="${patient_name}_CTA_${label_for_name}"
        else
          # Not CTA → classify CT as Post vs Pre using 'post' in SeriesDescription
          if echo "${series_desc:-}" | grep -qi "post"; then
            series_out_dir="$patient_out/CT_Post"
            out_pattern="${patient_name}_CT_Post_${label_for_name}"
          else
            series_out_dir="$patient_out/CT_Pre"
            out_pattern="${patient_name}_CT_Pre_${label_for_name}"
          fi
        fi

        mkdir -p "$series_out_dir"
      fi

      # Route MRI T1 (include label in filename)
      if [[ "$modality" == "MR" ]]; then
        if echo "${series_desc:-}" | grep -qi "T1"; then
          series_out_dir="$patient_out/MRI_T1"
          out_pattern="${patient_name}_MRI_T1_${label_for_name}"
          mkdir -p "$series_out_dir"
        fi
      fi

      # Ensure unique filename if multiple series of same category exist
      out_pattern="$(unique_basename "$series_out_dir" "$out_pattern")"

      # Run conversion silently: suppress all dcm2niix warnings/errors
      dcm2niix -b n -z y -f "$out_pattern" -o "$series_out_dir" "$series_dir" 2>/dev/null

    else
      # Not a CT or MRI-T1 series and not a handled SEG → just log as skipped
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