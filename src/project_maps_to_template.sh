#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
# ==============================================================================
# Script: project_maps_to_template.sh
# Description:
#   Warps individual parametric maps (e.g., T1map, UNIT1) into the Study-Specific 
#   Template space. It uses the transforms generated during the template construction.
#
# Usage:
#   ./project_maps_to_template.sh <modality>
#
# Arguments:
#   1. modality : The name of the modality (folder name) to project (e.g., "T1map").
#
# Parameters (Environment Variables):
#   BRAIN_EXTRACTED_DIR : Root inputs directory.
#   TARGET_GROUP        : Name of the group template to target (default: "study").
#   INPUT_MODE          : "allen", "aligned", or "raw".
#                         - "allen"/"aligned": Uses data from aligned/ subdirectory.
#                         - "raw": Uses data directly from modality root.
#   INTERP              : Interpolation method (default: BSpline[3]).
#
# Outputs:
#   - derivatives/Brain_extracted/<MODALITY>/To_Template/<GROUP>/
#     Contains the maps warped into the group template space (*_in_template.nii.gz).
# ==============================================================================

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

if [[ $# -lt 1 ]]; then echo "Usage: $0 <modality>"; exit 1; fi
MODALITY="$1"

BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$PWD}"
INPUT_MODE="${INPUT_MODE:-allen}"

case "$INPUT_MODE" in
  allen|aligned) DATA_DIR="$BRAIN_EXTRACTED_DIR/${MODALITY}/aligned" ;;
  raw)           DATA_DIR="$BRAIN_EXTRACTED_DIR/${MODALITY}" ;;
  *) log_err "INPUT_MODE must be allen|aligned|raw"; exit 1 ;;
esac

# T2starmap special case: "thresholded" instead of "seuil"
if [[ "$MODALITY" == "T2starmap" && "$INPUT_MODE" != "raw" ]]; then
  [[ -d "$BRAIN_EXTRACTED_DIR/T2starmap/aligned/thresholded" ]] && DATA_DIR="$BRAIN_EXTRACTED_DIR/T2starmap/aligned/thresholded" # NEW NAME
fi

TARGET_GROUP="${TARGET_GROUP:-study}"
OUTPUT_BASE="$BRAIN_EXTRACTED_DIR/${MODALITY}/To_Template"
INTERP="${INTERP:-BSpline[3]}"
FORCE_RERUN="${FORCE_RERUN:-0}"

# New Template Path Logic
DERIVATIVES_DIR="$(dirname "$BRAIN_EXTRACTED_DIR")"
TEMPLATE_DIR="$DERIVATIVES_DIR/templates/${TARGET_GROUP}/RARE/res-0.1mm"
TEMPLATE="$TEMPLATE_DIR/${TARGET_GROUP}_RARE_template.nii.gz"

if [[ ! -f "$TEMPLATE" ]]; then
  log_err "Template not found: $TEMPLATE"
  exit 1
fi

log_info "Apply RARE-template -> $MODALITY ($TARGET_GROUP)"

parse_map_name() {
  local base="$1"
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    sub="${BASH_REMATCH[1]}"; ses="ses-${BASH_REMATCH[2]}"; map_suffix="${BASH_REMATCH[3]}"; return 0
  elif [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    sub="${BASH_REMATCH[1]}"; ses="ses-1"; map_suffix="${BASH_REMATCH[2]}"; return 0
  fi
  return 1
}

OUTPUT_DIR="${OUTPUT_BASE}/${TARGET_GROUP}"
mkdir -p "$OUTPUT_DIR"

for map_file in "$DATA_DIR"/*.nii*; do
  [[ -f "$map_file" ]] || continue
  map_name="$(basename "$map_file")"
  map_base="${map_name%.nii.gz}"; map_base="${map_base%.nii}"

  if ! parse_map_name "$map_base"; then continue; fi

  output_file="${OUTPUT_DIR}/${sub}_${ses}_${map_suffix}_in_template.nii.gz"
  if [[ -f "$output_file" && "$FORCE_RERUN" != "1" ]]; then continue; fi

  # Look for transforms in the new template dir
  warp="$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*${sub}_${ses}*_RARE*1Warp.nii.gz" | head -n 1)"
  affine="$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*${sub}_${ses}*_RARE*0GenericAffine.mat" | head -n 1)"
  
  if [[ -z "$warp" ]]; then
      warp="$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*${sub}_RARE*1Warp.nii.gz" | head -n 1)"
      affine="$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*${sub}_RARE*0GenericAffine.mat" | head -n 1)"
  fi

  if [[ ! -f "${warp:-}" || ! -f "${affine:-}" ]]; then
    log_warn "Missing transforms for ${sub} ${ses}"
    continue
  fi

  antsApplyTransforms -d 3 -i "$map_file" -o "$output_file" -r "$TEMPLATE" \
    -t "$warp" -t "$affine" -n "$INTERP" --float 1
    
  log_ok "Wrote: $output_file"
done