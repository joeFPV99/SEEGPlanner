#!/bin/bash
# ==========================================
# Batch CTA Vesselness Filtering (pure VMTK logic import)
# ==========================================

SLICER_BIN="/Applications/Slicer.app/Contents/MacOS/Slicer"
SCRIPT_PATH="/Users/jonasludwig/Desktop/Masterthesis/3D-Slicer/SEEGPlanner/VesselSegPipeline/vesselTree_vmtk_headless.py"

INPUT_ROOT="/Users/jonasludwig/Desktop/Masterthesis/3D-Slicer/SEEGPlanner/VesselSegPipeline/Data"
OUTPUT_ROOT="/Users/jonasludwig/Desktop/Masterthesis/3D-Slicer/SEEGPlanner/VesselSegPipeline/OUT"

SIGMA_MIN=0.5
SIGMA_MAX=3.0

echo "[run] Using Slicer: $SLICER_BIN"
echo "[run] Using script: $SCRIPT_PATH"
echo "[run] Input root:   $INPUT_ROOT"
echo "[run] Output root:  $OUTPUT_ROOT"
echo "[run] Sigma range:  $SIGMA_MIN-$SIGMA_MAX"
echo "=========================================="

for CASEDIR in "$INPUT_ROOT"/*/; do
  [ -d "$CASEDIR" ] || continue
  CASENAME=$(basename "$CASEDIR")
  OUTDIR="$OUTPUT_ROOT/$CASENAME"
  mkdir -p "$OUTDIR"

  CTA_FILE=$(find "$CASEDIR" -type f -name "*.nrrd" | head -n1)
  if [ -z "$CTA_FILE" ]; then
    echo "[skip] No .nrrd found in $CASEDIR"
    continue
  fi

  echo "================================"
  echo "[case] $CASENAME ($(ls "$CASEDIR" | grep -c .) file(s)))"
  echo "  - Processing: $(basename "$CTA_FILE")"

  "$SLICER_BIN" \
    --no-main-window \
    --ignore-slicerrc \
    --disable-settings \
    --python-script "$SCRIPT_PATH" \
    -- \
    --input "$CTA_FILE" \
    --output-dir "$OUTDIR" \
    --sigma-min "$SIGMA_MIN" \
    --sigma-max "$SIGMA_MAX"

  echo "[done] $CASENAME"
done


echo "#####################"
echo "[all cases completed]"
echo "#####################"