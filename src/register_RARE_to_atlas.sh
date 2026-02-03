#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ==============================================================================
# Script: register_RARE_to_atlas.sh
# Description:
#   Registers RARE anatomical images to the Allen Brain Atlas reference.
#   This is the foundational step that generates the warp fields and affine
#   matrices used to propagate other modalities (T1, T2*, etc.) to the atlas.
#
# Usage:
#   ./register_RARE_to_atlas.sh
#
# Parameters (Environment Variables):
#   BRAIN_EXTRACTED_DIR : Path to 'derivatives/Brain_extracted'.
#                         Defaults to $PWD if not set.
#   DATA_DIR            : Directory containing RARE images.
#                         Defaults to $BRAIN_EXTRACTED_DIR/RARE.
#   ALLEN_TEMPLATE      : Path to the fixed reference image (Allen Atlas).
#                         Defaults to ./resources/100_AMBA_ref.nii.gz.
#   TRANSFORM_TYPE      : Registration type passed to antsRegistrationSyN.sh.
#                         's' = SyN (deformable), 'a' = Rigid+Affine. Defaults to 'a'.
#   N_THREADS           : Number of CPU threads for ANTs. Defaults to 8.
#
# Outputs:
#   - <DATA_DIR>/transforms/ : Contains .mat (affine) and .nii.gz (warp) files.
#   - <DATA_DIR>/aligned/    : Contains RARE images resampled to Allen space.
# ==============================================================================

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$PWD}"
DATA_DIR="${DATA_DIR:-$BRAIN_EXTRACTED_DIR/RARE}"

# Resource path update
ALLEN_TEMPLATE_DEFAULT="$SCRIPT_DIR/resources/100_AMBA_ref.nii.gz" # NEW NAME
ALLEN_TEMPLATE="${ALLEN_TEMPLATE:-$ALLEN_TEMPLATE_DEFAULT}"

TRANSFORM_TYPE="${TRANSFORM_TYPE:-a}"
N_THREADS="${N_THREADS:-8}"

[[ -d "$DATA_DIR" ]] || { log_err "DATA_DIR not found: $DATA_DIR"; exit 1; }
[[ -f "$ALLEN_TEMPLATE" ]] || { log_err "ALLEN_TEMPLATE not found"; exit 1; }

# Updated folder names
REG_DIR="${DATA_DIR}/transforms" # NEW NAME
FINAL_DIR="${DATA_DIR}/aligned"
mkdir -p "$REG_DIR" "$FINAL_DIR"

ALLEN_ID="$(basename "$ALLEN_TEMPLATE" | sed -E 's/\.nii(\.gz)?$//')"

log_info "Allen template : $ALLEN_TEMPLATE"
log_info "Transform dir  : $REG_DIR"
log_info "Transform type : $TRANSFORM_TYPE"

inputs=( "$DATA_DIR"/*_RARE_brain_extracted.nii.gz "$DATA_DIR"/*_RARE_brain_extracted.nii )
if [[ ${#inputs[@]} -eq 0 ]]; then
  log_warn "No inputs found in: $DATA_DIR"; exit 0
fi

for IMG in "${inputs[@]}"; do
  [[ -f "$IMG" ]] || continue
  BASE="$(basename "$IMG" | sed -E 's/\.nii(\.gz)?$//')"

  OUTPUT_FINAL="${FINAL_DIR}/${BASE}_aligned_to_${ALLEN_ID}.nii.gz"
  if [[ -f "$OUTPUT_FINAL" ]]; then
    log_skip "Exists: $OUTPUT_FINAL"
    continue
  fi

  log_info "Registering $BASE"
  OUT_PREFIX="${REG_DIR}/${BASE}_aligned_to_${ALLEN_ID}_"

  antsRegistrationSyN.sh -d 3 -f "$ALLEN_TEMPLATE" -m "$IMG" -o "$OUT_PREFIX" -t "$TRANSFORM_TYPE" -n "$N_THREADS"

  SRC_WARPED="${OUT_PREFIX}Warped.nii.gz"
  if [[ -f "$SRC_WARPED" ]]; then
    cp "$SRC_WARPED" "$OUTPUT_FINAL"
    log_ok "Aligned: $OUTPUT_FINAL"
  else
    log_err "Missing output: $SRC_WARPED"
    exit 1
  fi
done