#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }



if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <modality>"
  exit 1
fi
MODALITY="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

# INPUT_MODE:
#   - allen  : use Brain_extracted/<MODALITY>/aligned (Allen space)
#   - aligned: alias of allen (kept for backward-compat)
#   - raw    : use Brain_extracted/<MODALITY> (no pre-alignment)
INPUT_MODE="${INPUT_MODE:-allen}"
case "$INPUT_MODE" in
  allen|aligned) DATA_DIR="$BRAIN_EXTRACTED_DIR/${MODALITY}/aligned" ;;
  raw)           DATA_DIR="$BRAIN_EXTRACTED_DIR/${MODALITY}" ;;
  *) log_err "INPUT_MODE must be allen|aligned|raw (got: $INPUT_MODE)"; exit 1 ;;
esac

# Special case: T2starmap thresholded data (if present)
if [[ "$MODALITY" == "T2starmap" && "$INPUT_MODE" != "raw" ]]; then
  [[ -d "$BRAIN_EXTRACTED_DIR/T2starmap/aligned/seuil" ]] && DATA_DIR="$BRAIN_EXTRACTED_DIR/T2starmap/aligned/seuil"
fi

OUTPUT_BASE="$BRAIN_EXTRACTED_DIR/${MODALITY}/To_Template"
INTERP="${INTERP:-BSpline[3]}"
FORCE_RERUN="${FORCE_RERUN:-0}"

[[ -d "$DATA_DIR" ]] || { log_warn "No input dir for $MODALITY: $DATA_DIR"; exit 0; }

# Globals set by parse
sub=""
ses_num=""
ses=""
map_suffix=""

parse_map_name() {
  local base="$1"  # no extension
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    sub="${BASH_REMATCH[1]}"
    ses_num="${BASH_REMATCH[2]}"
    ses="ses-${ses_num}"
    map_suffix="${BASH_REMATCH[3]}"
  elif [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    # no session -> assume ses-1
    sub="${BASH_REMATCH[1]}"
    ses_num="1"
    ses="ses-1"
    map_suffix="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  # normalize potential leading zeros (e.g., "01" -> 1)
  ses_num=$((10#$ses_num))
  ses="ses-${ses_num}"
  return 0
}

log_info "Apply RARE-template transforms to modality: $MODALITY"
log_info "INPUT_MODE  : $INPUT_MODE"
log_info "DATA_DIR    : $DATA_DIR"
log_info "OUTPUT_BASE : $OUTPUT_BASE"
log_info "INTERP      : $INTERP"
log_info "FORCE_RERUN : $FORCE_RERUN"

for map_file in "$DATA_DIR"/*.nii*; do
  [[ -f "$map_file" ]] || continue

  map_name="$(basename "$map_file")"
  map_base="${map_name%.nii.gz}"
  map_base="${map_base%.nii}"

  if ! parse_map_name "$map_base"; then
    log_warn "Bad filename pattern (skip): $map_name"
    continue
  fi

  # Session -> group mapping
  if   [[ "$ses_num" -eq 1 || "$ses_num" -eq 2 ]]; then group="S01"
  elif [[ "$ses_num" -eq 3 || "$ses_num" -eq 4 ]]; then group="S02"
  elif [[ "$ses_num" -eq 5 || "$ses_num" -eq 6 ]]; then group="S03"
  else
    log_warn "Unknown session ($ses_num) for $map_name (skip)"
    continue
  fi

  TEMPLATE_DIR="$BRAIN_EXTRACTED_DIR/RARE/${group}/template/0.1/template"
  TEMPLATE="$TEMPLATE_DIR/${group}_RARE_template0.nii.gz"

  if [[ ! -f "$TEMPLATE" ]]; then
    log_warn "Missing RARE template for $group: $TEMPLATE (skip)"
    continue
  fi

  OUTPUT_DIR="${OUTPUT_BASE}/${group}"
  mkdir -p "$OUTPUT_DIR"

  output_file="${OUTPUT_DIR}/${sub}_${ses}_${map_suffix}_in_template.nii.gz"
  if [[ -f "$output_file" && "$FORCE_RERUN" != "1" ]]; then
    log_skip "Exists: $output_file"
    continue
  fi

  # Deterministic transform selection:
  # 1) Prefer session-tagged transforms, else fallback to subject-only.
  # Note: We sort results to make selection reproducible.
  warp="$(find "$TEMPLATE_DIR" -maxdepth 1 -type f -name "*${sub}_${ses}*_RARE*1Warp.nii.gz" | LC_ALL=C sort | head -n 1 || true)"
  affine="$(find "$TEMPLATE_DIR" -maxdepth 1 -type f -name "*${sub}_${ses}*_RARE*0GenericAffine.mat" | LC_ALL=C sort | head -n 1 || true)"

  if [[ -z "$warp" || -z "$affine" ]]; then
    warp="$(find "$TEMPLATE_DIR" -maxdepth 1 -type f -name "*${sub}_RARE*1Warp.nii.gz" | LC_ALL=C sort | head -n 1 || true)"
    affine="$(find "$TEMPLATE_DIR" -maxdepth 1 -type f -name "*${sub}_RARE*0GenericAffine.mat" | LC_ALL=C sort | head -n 1 || true)"
  fi

  if [[ ! -f "${warp:-/dev/null}" || ! -f "${affine:-/dev/null}" ]]; then
    log_warn "Missing transforms for ${sub} ${ses} in group ${group} (skip)"
    continue
  fi

  log_info "${sub} ${ses} -> template ${group}"

  antsApplyTransforms -d 3 \
    -i "$map_file" \
    -o "$output_file" \
    -r "$TEMPLATE" \
    -t "$warp" \
    -t "$affine" \
    -n "$INTERP" \
    --float 1

  log_ok "Wrote: $output_file"
done

log_ok "Done: applied template transforms for modality $MODALITY."
