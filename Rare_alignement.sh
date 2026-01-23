#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================================
# Rare_alignement.sh
#
# Purpose:
#   Register each RARE brain-extracted image to the Allen reference
#   using antsRegistrationSyN.sh, and write:
#     - transforms into: RARE/matrice_transforms/
#     - warped images into: RARE/aligned/
#
# Output naming:
#   - Final aligned image: <BASE>_aligned_to_<ALLEN_ID>.nii.gz
#   - Transform prefix   : <BASE>_to_<ALLEN_ID>_*
#
# Notes:
#   - BASE is the input filename without .nii/.nii.gz
#   - This script only processes *_RARE_brain_extracted.nii*
# ============================================================

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

# ------------------------
# Paths (overridable by env)
# ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

# Input folder containing RARE brain-extracted images
DATA_DIR="${DATA_DIR:-$BRAIN_EXTRACTED_DIR/RARE}"

# Allen reference (default shipped in the repo next to scripts)
ALLEN_TEMPLATE_DEFAULT="$SCRIPT_DIR/Ressources/100_AMBA_ref.nii.gz"
ALLEN_TEMPLATE="${ALLEN_TEMPLATE:-$ALLEN_TEMPLATE_DEFAULT}"

# Registration type for antsRegistrationSyN.sh:
#   a = rigid + affine
#   s = SyN (nonlinear)
TRANSFORM_TYPE="${TRANSFORM_TYPE:-a}"

# Threads used by antsRegistrationSyN.sh
N_THREADS="${N_THREADS:-8}"

# ------------------------
# Checks
# ------------------------
[[ -d "$DATA_DIR" ]] || { log_err "DATA_DIR not found: $DATA_DIR"; exit 1; }
[[ -f "$ALLEN_TEMPLATE" ]] || { log_err "ALLEN_TEMPLATE not found: $ALLEN_TEMPLATE"; exit 1; }

# Output folders (compatible with Mouse_Anat_Template.sh)
REG_DIR="${DATA_DIR}/matrice_transforms"
FINAL_DIR="${DATA_DIR}/aligned"
mkdir -p "$REG_DIR" "$FINAL_DIR"

ALLEN_ID="$(basename "$ALLEN_TEMPLATE" | sed -E 's/\.nii(\.gz)?$//')"

log_info "Allen template : $ALLEN_TEMPLATE (ID=$ALLEN_ID)"
log_info "Input dir      : $DATA_DIR"
log_info "Transform dir  : $REG_DIR"
log_info "Aligned dir    : $FINAL_DIR"
log_info "Transform type : $TRANSFORM_TYPE (a=affine, s=SyN)"
log_info "Threads        : $N_THREADS"

# Process only RARE brain-extracted images
inputs=( "$DATA_DIR"/*_RARE_brain_extracted.nii.gz "$DATA_DIR"/*_RARE_brain_extracted.nii )
if [[ ${#inputs[@]} -eq 0 ]]; then
  log_warn "No *_RARE_brain_extracted inputs found in: $DATA_DIR"
  exit 0
fi

for IMG in "${inputs[@]}"; do
  [[ -f "$IMG" ]] || continue
  BASE="$(basename "$IMG" | sed -E 's/\.nii(\.gz)?$//')"

  OUTPUT_FINAL="${FINAL_DIR}/${BASE}_aligned_to_${ALLEN_ID}.nii.gz"
  if [[ -f "$OUTPUT_FINAL" ]]; then
    log_skip "$BASE already aligned -> $OUTPUT_FINAL"
    continue
  fi

  log_info "Registering $BASE -> $ALLEN_ID"
  OUT_PREFIX="${REG_DIR}/${BASE}_aligned_to_${ALLEN_ID}_"

  antsRegistrationSyN.sh \
    -d 3 \
    -f "$ALLEN_TEMPLATE" \
    -m "$IMG" \
    -o "$OUT_PREFIX" \
    -t "$TRANSFORM_TYPE" \
    -n "$N_THREADS"

  # antsRegistrationSyN.sh produces:
  #   ${OUT_PREFIX}Warped.nii.gz        : moving -> fixed (mouse -> Allen)
  #   ${OUT_PREFIX}InverseWarped.nii.gz : fixed -> moving (Allen -> mouse)
  #   ${OUT_PREFIX}0GenericAffine.mat   : affine
  #   ${OUT_PREFIX}1Warp.nii.gz         : warp field (only when -t s)

  SRC_WARPED="${OUT_PREFIX}Warped.nii.gz"
  if [[ -f "$SRC_WARPED" ]]; then
    cp "$SRC_WARPED" "$OUTPUT_FINAL"
    log_ok "Aligned image: $OUTPUT_FINAL"
    log_info "Transforms kept in: $REG_DIR"
  else
    log_err "Missing warped output: $SRC_WARPED"
    exit 1
  fi
done

log_ok "Done: all RARE brain-extracted images aligned to Allen ($ALLEN_ID)."
