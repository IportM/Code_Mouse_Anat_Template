#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ==============================================================================
# Script: apply_transforms_to_maps.sh
# Description:
#   Applies existing spatial transformations (computed on RARE images) to other
#   parametric maps (e.g., T1map, T2map, T2starmap) to align them to the 
#   Allen Atlas space.
#
#   It matches each map to its corresponding RARE transform based on Subject/Session ID.
#
# Usage:
#   ./apply_transforms_to_maps.sh
#
# Parameters (Environment Variables):
#   BRAIN_DIR       : Root directory to search recursively (usually derivatives/Brain_extracted).
#                     Defaults to $PWD.
#   TRANSFORM_DIR   : Directory containing the .mat/.nii.gz files from RARE registration.
#                     Defaults to $BRAIN_DIR/RARE/transforms.
#   ALLEN_TEMPLATE  : Path to the reference image (required).
#   FORCE_RERUN     : Set to "1" to overwrite existing aligned files.
#   INTERP          : Interpolation method (e.g., Linear, NearestNeighbor, BSpline[3]).
#                     Defaults to BSpline[3].
#
# Outputs:
#   - Creates an 'aligned/' subdirectory next to each input map containing
#     the file resampled to the Allen space.
# ==============================================================================

log_info() { echo "[INFO] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }

basename_nii() {
  local f="$(basename "$1")"
  if [[ "$f" == *.nii.gz ]]; then echo "${f%.nii.gz}"; elif [[ "$f" == *.nii ]]; then echo "${f%.nii}"; else echo "$f"; fi
}

parse_sub_ses_suffix() {
  local base="$1"
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"; SES="ses-${BASH_REMATCH[2]}"; SUFFIX="${BASH_REMATCH[3]}"; CANON_BASE="$base";
  elif [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"; SES="ses-1"; SUFFIX="${BASH_REMATCH[2]}"; CANON_BASE="${SUB}_${SES}_${SUFFIX}";
  else return 1; fi
  SUBSES="${SUB}_${SES}"; return 0
}

BRAIN_DIR="${BRAIN_DIR:-$PWD}"
TRANSFORM_DIR="${TRANSFORM_DIR:-$BRAIN_DIR/RARE/transforms}"
ALLEN_TEMPLATE="${ALLEN_TEMPLATE:-required_env_var}"
FORCE_RERUN="${FORCE_RERUN:-0}"
INTERP="${INTERP:-BSpline[3]}"

ALLEN_ID="$(basename "$ALLEN_TEMPLATE" | sed -E 's/\.nii(\.gz)?$//')"

log_info "Align modalities -> Allen"
log_info "Transforms source: $TRANSFORM_DIR"

find "$BRAIN_DIR" -type f \( -iname '*_brain_extracted*.nii' -o -iname '*_brain_extracted*.nii.gz' \) -print | while read -r IMG; do
  PARENT_DIR="$(dirname "$IMG")"
  PARENT_NAME="$(basename "$PARENT_DIR")"

  # === FIX: PREVENT RECURSIVE ALIGNMENT ===
  # If file is already in 'aligned', 'transforms', or 'RARE', skip it.
  if [[ "$PARENT_NAME" == "aligned" || "$PARENT_NAME" == "transforms" || "$PARENT_NAME" == "RARE" ]]; then
    continue
  fi
  # Also safer check: if path contains /RARE/, skip (RARE is aligned by its own script)
  if [[ "$IMG" == *"/RARE/"* ]]; then continue; fi
  # ========================================

  IMG_BASE="$(basename_nii "$IMG")"
  if ! parse_sub_ses_suffix "$IMG_BASE"; then continue; fi

  RARE_FILE=""
  for cand in "$BRAIN_DIR/RARE/${SUBSES}_RARE_brain_extracted"* "$BRAIN_DIR/RARE/${SUB}_RARE_brain_extracted"*; do
    [[ -f "$cand" ]] && RARE_FILE="$cand" && break
  done
  if [[ -z "$RARE_FILE" ]]; then continue; fi
  RARE_BASE="$(basename_nii "$RARE_FILE")"

  AFFINE_MAT="${TRANSFORM_DIR}/${RARE_BASE}*_to_${ALLEN_ID}_0GenericAffine.mat"
  WARP_FIELD="${TRANSFORM_DIR}/${RARE_BASE}*_to_${ALLEN_ID}_1Warp.nii.gz"
  AFFINE_MAT="$(echo $AFFINE_MAT)"
  WARP_FIELD="$(echo $WARP_FIELD)"

  if [[ ! -f "$AFFINE_MAT" && ! -f "$WARP_FIELD" ]]; then continue; fi

  TRANSFORMS=()
  [[ -f "$WARP_FIELD" ]] && TRANSFORMS+=(-t "$WARP_FIELD")
  TRANSFORMS+=(-t "$AFFINE_MAT")

  OUT_DIR="${PARENT_DIR}/aligned"
  mkdir -p "$OUT_DIR"
  OUT_FILE="${OUT_DIR}/${CANON_BASE}_aligned_to_${ALLEN_ID}.nii.gz"

  if [[ -f "$OUT_FILE" && "$FORCE_RERUN" != "1" ]]; then continue; fi

  if [[ "$PARENT_NAME" == "T2starmap" || "$PARENT_NAME" == "QSM" ]]; then
    hdr_img="${OUT_DIR}/${CANON_BASE}_tmp_hdr.nii.gz"
    CopyImageHeaderInformation "$RARE_FILE" "$IMG" "$hdr_img" 1 1 1
    INPUT_IMG="$hdr_img"
  else
    INPUT_IMG="$IMG"
  fi

  antsApplyTransforms -d 3 -i "$INPUT_IMG" -r "$ALLEN_TEMPLATE" -o "$OUT_FILE" -n "$INTERP" --float 1 "${TRANSFORMS[@]}"
  
  [[ "$INPUT_IMG" == *"_tmp_hdr"* ]] && rm -f "$INPUT_IMG"
  log_ok "Wrote: $OUT_FILE"
done