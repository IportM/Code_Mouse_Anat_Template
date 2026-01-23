#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================================
# Rare_Template.sh
#
# Build a multi-resolution ANTs template for a given contrast and session group.
#
# Expected pipeline conventions:
#   - RARE images aligned to Allen are in: Brain_extracted/<contrast>/aligned/
#   - Templates are written to:           Brain_extracted/<contrast>/<GROUP>/template/<res>/template/
#   - Final template (for res=0.1):       .../template/0.1/template/<GROUP>_<contrast>_template.nii.gz
#
# Usage:
#   Rare_Template.sh <contrast> [S01|S02|S03] [nIter]
#
# Env overrides:
#   TEMPLATE_THREADS, INPUT_MODE, FORCE_RERUN, FORCE_ALLEN_GRID, ALLEN_REF_TEMPLATE, ANTS_GEN_ITER
# ============================================================

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing dependency in PATH: $1"; exit 1; }
}

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

# Parse sub/ses from any filename that starts with:
#   sub-XX_ses-Y_...   OR   sub-XX_...
SUB=""
SES=""
CANON_BASE=""

parse_sub_ses_prefix() {
  local base="$1"
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"
    SES_NUM="${BASH_REMATCH[2]}"
    SES="ses-${SES_NUM}"
    CANON_BASE="$base"
    return 0
  elif [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"
    SES_NUM="1"
    SES="ses-1"
    CANON_BASE="${SUB}_${SES}_${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

usage() {
  echo "Usage: $(basename "$0") <contrast> [S01|S02|S03] [nIter]"
  exit 1
}

[[ $# -ge 1 ]] || usage
contrast="$1"                  # e.g. RARE
session_group="${2:-S01}"      # S01, S02, S03
nIter="${3:-4}"                # iterations for antsMultivariateTemplateConstruction2.sh
nThreads="${TEMPLATE_THREADS:-16}"

# Resolution pyramid
resolutions=(0.5 0.3 0.2 0.1)

# -----------------------------
# Session grouping
# -----------------------------
case "$session_group" in
  S01) ses_filter=("ses-1" "ses-2") ;;
  S02) ses_filter=("ses-3" "ses-4") ;;
  S03) ses_filter=("ses-5" "ses-6") ;;
  *) log_err "session_group must be S01, S02, or S03"; exit 1 ;;
esac

# -----------------------------
# Paths (overridable by env)
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

# resources folder 
RESOURCES_DIR="$SCRIPT_DIR/Ressources"

# third_party folder (accept both 'third_party' and 'Third_party')
THIRD_PARTY_DIR="$SCRIPT_DIR/third_party"
[[ -d "$THIRD_PARTY_DIR" ]] || THIRD_PARTY_DIR="$SCRIPT_DIR/Third_party"

# -----------------------------
# INPUT selection
# -----------------------------
# INPUT_MODE:
#   - auto   : use aligned/ if it exists, else raw Brain_extracted/<contrast>/
#   - raw    : Brain_extracted/<contrast>/
#   - aligned: Brain_extracted/<contrast>/aligned/
INPUT_MODE="${INPUT_MODE:-auto}"

RAW_DIR="$BRAIN_EXTRACTED_DIR/${contrast}"
ALIGNED_DIR="$RAW_DIR/aligned"

case "$INPUT_MODE" in
  auto)
    if [[ -d "$ALIGNED_DIR" ]]; then ORIG_IMG_DIR="$ALIGNED_DIR"
    else ORIG_IMG_DIR="$RAW_DIR"
    fi
    ;;
  raw) ORIG_IMG_DIR="$RAW_DIR" ;;
  aligned)
    [[ -d "$ALIGNED_DIR" ]] || { log_err "aligned directory not found: $ALIGNED_DIR"; exit 1; }
    ORIG_IMG_DIR="$ALIGNED_DIR"
    ;;
  *) log_err "Invalid INPUT_MODE: $INPUT_MODE (auto|raw|aligned)"; exit 1 ;;
esac

# -----------------------------
# OUTPUT base (pipeline convention)
# -----------------------------
TEMPLATE_BASE="$BRAIN_EXTRACTED_DIR/${contrast}/${session_group}/template"
FINAL_TEMPLATE="$TEMPLATE_BASE/0.1/template/${session_group}_${contrast}_template0.nii.gz"
FORCE_RERUN="${FORCE_RERUN:-0}"

if [[ -f "$FINAL_TEMPLATE" && "$FORCE_RERUN" != "1" ]]; then
  log_skip "Final template already exists: $FINAL_TEMPLATE"
  exit 0
fi

mkdir -p "$TEMPLATE_BASE"


# ants_generate_iterations.py (vendored)
ANTS_GEN_ITER_DEFAULT="$THIRD_PARTY_DIR/minc-toolkit-extras/ants_generate_iterations.py"
ANTS_GEN_ITER="${ANTS_GEN_ITER:-$ANTS_GEN_ITER_DEFAULT}"
[[ -f "$ANTS_GEN_ITER" ]] || { log_err "ants_generate_iterations.py not found: $ANTS_GEN_ITER"; exit 1; }

# Allen reference grid for optional regridding at final res
ALLEN_REF_TEMPLATE_DEFAULT="$RESOURCES_DIR/100_AMBA_ref.nii.gz"
ALLEN_REF_TEMPLATE="${ALLEN_REF_TEMPLATE:-$ALLEN_REF_TEMPLATE_DEFAULT}"

log_info "Contrast        : $contrast"
log_info "Session group   : $session_group (sessions: ${ses_filter[*]})"
log_info "INPUT_MODE      : $INPUT_MODE"
log_info "ORIG_IMG_DIR    : $ORIG_IMG_DIR"
log_info "TEMPLATE_BASE   : $TEMPLATE_BASE"
log_info "Threads         : $nThreads"
log_info "Iterations      : $nIter"
log_info "ants_gen_iters  : $ANTS_GEN_ITER"

prev_template=""

for res in "${resolutions[@]}"; do
  TEMPLATE_OUT="$TEMPLATE_BASE/${res}/template"
  RESAMPLED_DIR="$TEMPLATE_BASE/${res}/resampled"
  mkdir -p "$TEMPLATE_OUT" "$RESAMPLED_DIR"

  # Build input list: resample all selected files to current resolution
  inputs=()

  for f in "$ORIG_IMG_DIR"/*.nii*; do
    [[ -f "$f" ]] || continue

    filename="$(basename "$f")"
    # Only keep files likely belonging to this contrast
    # (avoid picking masks/other modalities by accident)
    if [[ "$filename" != *"_${contrast}_"* ]]; then
      continue
    fi

    base="$(basename_nii "$f")"
    if ! parse_sub_ses_prefix "$base"; then
      log_warn "Cannot parse sub/ses from: $filename (skip)"
      continue
    fi

    # Session filter
    keep=0
    for sf in "${ses_filter[@]}"; do
      [[ "$SES" == "$sf" ]] && keep=1 && break
    done
    [[ "$keep" -eq 1 ]] || continue

    # Canonicalize output name (adds ses-1 if missing)
    resampled_img="${RESAMPLED_DIR}/${CANON_BASE}_res-${res}.nii.gz"
    if [[ ! -f "$resampled_img" ]]; then
      log_info "Resampling $filename to ${res} mm (as ${CANON_BASE})"
      ResampleImageBySpacing 3 "$f" "$resampled_img" "$res" "$res" "$res" 0
    else
      log_skip "Resampled exists: $resampled_img"
    fi

    inputs+=("$resampled_img")
  done

  if [[ ${#inputs[@]} -eq 0 ]]; then
    log_warn "No resampled inputs found for ${session_group} at ${res} mm. Exiting."
    exit 0
  fi

  # FOV estimate (for dynamic parameter generation)
  test_img="${inputs[0]}"
  dims=($(mrinfo -size "$test_img"))
  spacing=($(mrinfo -spacing "$test_img"))

  fov_x=$(echo "${dims[0]} * ${spacing[0]}" | bc -l)
  fov_y=$(echo "${dims[1]} * ${spacing[1]}" | bc -l)
  fov_z=$(echo "${dims[2]} * ${spacing[2]}" | bc -l)

  FOV_MAX=$(printf "%.2f\n" $(echo "$fov_x $fov_y $fov_z" | tr ' ' '\n' | sort -nr | head -n1))
  log_info "Estimated FOV max: ${FOV_MAX} mm"

  # Dynamic params from vendored script
  GEN_PARAMS=$(python3 "$ANTS_GEN_ITER" --min "$res" --max "$FOV_MAX" --step-size 1 --output modelbuild | tr -d '\\')
  readarray -t PARAM_ARRAY <<< "$GEN_PARAMS"
  Q_PARAM=${PARAM_ARRAY[0]:-}
  F_PARAM=${PARAM_ARRAY[1]:-}
  S_PARAM=${PARAM_ARRAY[2]:-}
  log_info "Optimized params for ${res} mm: ${Q_PARAM} ${F_PARAM} ${S_PARAM}"

  # Build command
  cd "$TEMPLATE_OUT"
  log_info "Inputs ready for template at ${res} mm: ${#inputs[@]} file(s)"

  cmd=(
    antsMultivariateTemplateConstruction2.sh
    -d 3
    -o "${session_group}_${contrast}_"
    -i "$nIter"
    -g 0.1
    -c 2
    -j "$nThreads"
    -k 1
    -w 1
    -n 0
    -r 1
  )
  [[ -n "$Q_PARAM" ]] && cmd+=("$Q_PARAM")
  [[ -n "$F_PARAM" ]] && cmd+=("$F_PARAM")
  [[ -n "$S_PARAM" ]] && cmd+=("$S_PARAM")

  # Reference (-z): Allen for first level if available, else previous template
  REF_TEMPLATE=""
  if [[ -z "$prev_template" ]]; then
    [[ -f "$ALLEN_REF_TEMPLATE" ]] && REF_TEMPLATE="$ALLEN_REF_TEMPLATE"
  else
    [[ -f "$prev_template" ]] && REF_TEMPLATE="$prev_template"
  fi

  if [[ -n "$REF_TEMPLATE" && -f "$REF_TEMPLATE" ]]; then
    REF_RESAMPLED="${TEMPLATE_OUT}/ref_template_res-${res}.nii.gz"
    if [[ ! -f "$REF_RESAMPLED" ]]; then
      log_info "Resampling reference for -z: $REF_TEMPLATE -> ${res} mm"
      ResampleImageBySpacing 3 "$REF_TEMPLATE" "$REF_RESAMPLED" "$res" "$res" "$res" 0
    fi
    cmd+=(-z "$REF_RESAMPLED")
    log_info "Using reference (-z): $REF_RESAMPLED"
  fi

  log_info "Building template at ${res} mm..."
  "${cmd[@]}" "${inputs[@]}"

  NEW_TEMPLATE="${TEMPLATE_OUT}/${session_group}_${contrast}_template0.nii.gz"
  if [[ ! -f "$NEW_TEMPLATE" ]]; then
    log_err "Template not found after build: $NEW_TEMPLATE"
    exit 1
  fi

  # Final regridding on Allen grid to prevent cropping (optional)
  if [[ "$res" == "0.1" && "${FORCE_ALLEN_GRID:-1}" == "1" ]]; then
    if [[ -f "$ALLEN_REF_TEMPLATE" ]]; then
      tmp_out="${NEW_TEMPLATE%.nii.gz}_tmp_inAllenGrid.nii.gz"
      log_info "Regridding final template onto Allen grid:"
      log_info "  template : $NEW_TEMPLATE"
      log_info "  reference: $ALLEN_REF_TEMPLATE"

      antsApplyTransforms -d 3 \
        -i "$NEW_TEMPLATE" \
        -r "$ALLEN_REF_TEMPLATE" \
        -o "$tmp_out" \
        -n Linear \
        -t identity

      mv -f "$tmp_out" "$NEW_TEMPLATE"
      log_ok "Regridded final template: $NEW_TEMPLATE"
    else
      log_warn "FORCE_ALLEN_GRID=1 but ALLEN_REF_TEMPLATE not found: $ALLEN_REF_TEMPLATE (skip regrid)"
    fi
  fi

  prev_template="$NEW_TEMPLATE"
  log_ok "Template ready at ${res} mm: $NEW_TEMPLATE"
done

log_ok "Done. Final template: $FINAL_TEMPLATE"
