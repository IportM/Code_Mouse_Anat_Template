#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================================
# Align.sh
#
# Purpose:
#   Apply RARE->Allen transforms to ALL other brain-extracted modalities
#   and write outputs into each modality's "aligned/" folder.
#
# Conventions (must match Rare_alignement.sh + driver):
#   - RARE transforms are stored in:  <Brain_extracted>/RARE/matrice_transforms/
#   - Transform prefix:              <RARE_BASE>_to_<ALLEN_ID>_*
#   - Output images:                 <CANON_BASE>_aligned_to_<ALLEN_ID>.nii.gz
#
# Notes:
#   - If an input filename has no "ses-XX", we assume "ses-1" for matching.
#   - RARE itself is skipped (it is aligned by Rare_alignement.sh).
# ============================================================

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

basename_nii() {
  local f
  f="$(basename "$1")"
  if [[ "$f" == *.nii.gz ]]; then
    echo "${f%.nii.gz}"
  elif [[ "$f" == *.nii ]]; then
    echo "${f%.nii}"
  else
    echo "$f"
  fi
}

# Globals set by parse
SUB=""
SES_NUM=""
SES=""
SUFFIX=""
CANON_BASE=""
SUBSES=""

parse_sub_ses_suffix() {
  local base="$1"

  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"
    SES_NUM="${BASH_REMATCH[2]}"
    SES="ses-${SES_NUM}"
    SUFFIX="${BASH_REMATCH[3]}"
    CANON_BASE="$base"
  elif [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    # no session -> assume ses-1
    SUB="${BASH_REMATCH[1]}"
    SES_NUM="1"
    SES="ses-1"
    SUFFIX="${BASH_REMATCH[2]}"
    CANON_BASE="${SUB}_${SES}_${SUFFIX}"
  else
    return 1
  fi

  SUBSES="${SUB}_${SES}"
  return 0
}

# ------------------------
# Paths (overridable by env)
# ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"
BRAIN_DIR="${BRAIN_DIR:-$BRAIN_EXTRACTED_DIR}"

ALLEN_TEMPLATE_DEFAULT="$SCRIPT_DIR/Resources/100_AMBA_ref.nii.gz"
ALLEN_TEMPLATE="${ALLEN_TEMPLATE:-$ALLEN_TEMPLATE_DEFAULT}"

TRANSFORM_DIR_DEFAULT="$BRAIN_EXTRACTED_DIR/RARE/matrice_transforms"
TRANSFORM_DIR="${TRANSFORM_DIR:-$TRANSFORM_DIR_DEFAULT}"

FORCE_RERUN="${FORCE_RERUN:-0}"
INTERP="${INTERP:-BSpline[3]}"

# ------------------------
# Checks
# ------------------------
# require_cmd antsApplyTransforms
# require_cmd CopyImageHeaderInformation

[[ -d "$BRAIN_DIR" ]]      || { log_err "BRAIN_DIR not found: $BRAIN_DIR"; exit 1; }
[[ -d "$TRANSFORM_DIR" ]]  || { log_err "TRANSFORM_DIR not found: $TRANSFORM_DIR"; exit 1; }
[[ -f "$ALLEN_TEMPLATE" ]] || { log_err "ALLEN_TEMPLATE not found: $ALLEN_TEMPLATE"; exit 1; }

ALLEN_ID="$(basename "$ALLEN_TEMPLATE" | sed -E 's/\.nii(\.gz)?$//')"

log_info "=== Align all modalities to Allen (apply RARE transforms) ==="
log_info "Allen template : $ALLEN_TEMPLATE (ID=$ALLEN_ID)"
log_info "Transform dir  : $TRANSFORM_DIR"
log_info "Brain dir      : $BRAIN_DIR"
log_info "Rule           : if no session in filename -> assume ses-1"
log_info "Interpolation  : $INTERP"
log_info "Force rerun    : $FORCE_RERUN"

# Find all brain_extracted images excluding already aligned folders
find "$BRAIN_DIR" \
  -type f \( -iname '*_brain_extracted*.nii' -o -iname '*_brain_extracted*.nii.gz' \) -print \
| while read -r IMG; do

  PARENT_ACQ="$(basename "$(dirname "$IMG")")"  # modality name (RARE, T1map, UNIT1, ...)
  [[ "$PARENT_ACQ" == "RARE" ]] && continue

  IMG_BASE="$(basename_nii "$IMG")"
  if ! parse_sub_ses_suffix "$IMG_BASE"; then
    log_warn "Cannot parse subject/session from: $IMG_BASE -> skip"
    continue
  fi

  # Deterministic lookup of corresponding RARE brain_extracted
  RARE1="$BRAIN_DIR/RARE/${SUBSES}_RARE_brain_extracted*.nii.gz"
  RARE2="$BRAIN_DIR/RARE/${SUBSES}_RARE_brain_extracted*.nii"
  RARE3="$BRAIN_DIR/RARE/${SUB}_RARE_brain_extracted*.nii.gz"
  RARE4="$BRAIN_DIR/RARE/${SUB}_RARE_brain_extracted*.nii"

  if   [[ -f "$RARE1" ]]; then RARE_FILE="$RARE1"
  elif [[ -f "$RARE2" ]]; then RARE_FILE="$RARE2"
  elif [[ -f "$RARE3" ]]; then RARE_FILE="$RARE3"
  elif [[ -f "$RARE4" ]]; then RARE_FILE="$RARE4"
  else
    log_warn "No RARE found for ${SUBSES} (or ${SUB}) -> skip $IMG_BASE"
    continue
  fi

  RARE_BASE="$(basename_nii "$RARE_FILE")"

  AFFINE_MAT="${TRANSFORM_DIR}/${RARE_BASE}*_to_${ALLEN_ID}_0GenericAffine.mat"
  WARP_FIELD="${TRANSFORM_DIR}/${RARE_BASE}*_to_${ALLEN_ID}_1Warp.nii.gz"

  if [[ ! -f "$AFFINE_MAT" && ! -f "$WARP_FIELD" ]]; then
    log_warn "No transform (affine/warp) for ${SUBSES} using RARE_BASE=$RARE_BASE -> skip $IMG_BASE"
    continue
  fi

  TRANSFORMS=()
  if [[ -f "$WARP_FIELD" ]]; then
    TRANSFORMS=(-t "$WARP_FIELD" -t "$AFFINE_MAT")
  else
    TRANSFORMS=(-t "$AFFINE_MAT")
  fi

  OUT_DIR="$(dirname "$IMG")/aligned"
  mkdir -p "$OUT_DIR"

  # Output name is canonicalized (adds ses-1 if missing)
  OUT_FILE="${OUT_DIR}/${CANON_BASE}_aligned_to_${ALLEN_ID}.nii.gz"

  if [[ -f "$OUT_FILE" && "$FORCE_RERUN" != "1" ]]; then
    log_skip "Already done: $OUT_FILE"
    continue
  fi

  log_info "Align ${CANON_BASE} -> Allen (from $IMG_BASE)"

  # Some map modalities may carry inconsistent headers; copy header info from RARE to the map before resampling.
  if [[ "$PARENT_ACQ" == "T2starmap" || "$PARENT_ACQ" == "QSM" ]]; then
    hdr_img="${OUT_DIR}/${CANON_BASE}_tmp_hdr.nii.gz"
    CopyImageHeaderInformation "$RARE_FILE" "$IMG" "$hdr_img" 1 1 1

    antsApplyTransforms -d 3 \
      -i "$hdr_img" \
      -r "$ALLEN_TEMPLATE" \
      -o "$OUT_FILE" \
      -n "$INTERP" \
      --float 1 \
      "${TRANSFORMS[@]}"

    rm -f "$hdr_img"
  else
    antsApplyTransforms -d 3 \
      -i "$IMG" \
      -r "$ALLEN_TEMPLATE" \
      -o "$OUT_FILE" \
      -n "$INTERP" \
      --float 1 \
      "${TRANSFORMS[@]}"
  fi

  log_ok "Wrote: $OUT_FILE"
done

log_ok "Done: modalities in Allen space."
