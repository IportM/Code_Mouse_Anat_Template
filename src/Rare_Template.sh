#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================================
# Rare_Template.sh (Cleaner Output Structure)
# Output: derivatives/templates/<GROUP>/<CONTRAST>/
# ============================================================

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }

basename_nii() {
  local f="$(basename "$1")"
  if [[ "$f" == *.nii.gz ]]; then echo "${f%.nii.gz}"; elif [[ "$f" == *.nii ]]; then echo "${f%.nii}"; else echo "$f"; fi
}

parse_sub_ses_prefix() {
  local base="$1"
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"; SES_NUM="${BASH_REMATCH[2]}"; SES="ses-${SES_NUM}"; CANON_BASE="$base"; return 0
  elif [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    SUB="${BASH_REMATCH[1]}"; SES_NUM="1"; SES="ses-1"; CANON_BASE="${SUB}_${SES}_${BASH_REMATCH[2]}"; return 0
  fi
  return 1
}

[[ $# -ge 1 ]] || { echo "Usage: $0 <contrast> [Group_Name] [Session_Filter]"; exit 1; }
contrast="$1"
session_group="${2:-study}"
session_filter_str="${3:-}"
nIter="${4:-4}"
nThreads="${TEMPLATE_THREADS:-16}"

resolutions=(0.5 0.3 0.2 0.1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$PWD}"
# We assume BRAIN_EXTRACTED_DIR is derivatives/Brain_extracted
# Let's target derivatives/templates for the output
DERIVATIVES_DIR="$(dirname "$BRAIN_EXTRACTED_DIR")"
TEMPLATE_ROOT="$DERIVATIVES_DIR/templates/${session_group}/${contrast}"

RESOURCES_DIR="$SCRIPT_DIR/resources" # NEW NAME
THIRD_PARTY_DIR="$SCRIPT_DIR/third_party"
[[ -d "$THIRD_PARTY_DIR" ]] || THIRD_PARTY_DIR="$SCRIPT_DIR/Third_party"

INPUT_MODE="${INPUT_MODE:-auto}"
RAW_DIR="$BRAIN_EXTRACTED_DIR/${contrast}"
ALIGNED_DIR="$RAW_DIR/aligned"

case "$INPUT_MODE" in
  auto) if [[ -d "$ALIGNED_DIR" ]]; then ORIG_IMG_DIR="$ALIGNED_DIR"; else ORIG_IMG_DIR="$RAW_DIR"; fi ;;
  raw) ORIG_IMG_DIR="$RAW_DIR" ;;
  aligned) ORIG_IMG_DIR="$ALIGNED_DIR" ;;
esac

FINAL_TEMPLATE="$TEMPLATE_ROOT/res-0.1mm/${session_group}_${contrast}_template.nii.gz"
FORCE_RERUN="${FORCE_RERUN:-0}"

if [[ -f "$FINAL_TEMPLATE" && "$FORCE_RERUN" != "1" ]]; then
  log_skip "Template exists: $FINAL_TEMPLATE"
  exit 0
fi

ANTS_GEN_ITER="${ANTS_GEN_ITER:-$THIRD_PARTY_DIR/minc-toolkit-extras/ants_generate_iterations.py}"
ALLEN_REF_TEMPLATE="${ALLEN_REF_TEMPLATE:-$RESOURCES_DIR/100_AMBA_ref.nii.gz}"

allowed_sessions=()
if [[ -n "$session_filter_str" ]]; then IFS=',' read -r -a allowed_sessions <<< "$session_filter_str"; fi

log_info "Target : $TEMPLATE_ROOT"
prev_template=""

for res in "${resolutions[@]}"; do
  # Clean structure: templates/study/RARE/res-0.1mm/
  WORK_DIR="$TEMPLATE_ROOT/res-${res}mm"
  mkdir -p "$WORK_DIR"

  inputs=()
  for f in "$ORIG_IMG_DIR"/*.nii*; do
    [[ -f "$f" ]] || continue
    filename="$(basename "$f")"
    [[ "$filename" == *"_${contrast}_"* ]] || continue
    base="$(basename_nii "$f")"
    if ! parse_sub_ses_prefix "$base"; then continue; fi

    if [[ ${#allowed_sessions[@]} -gt 0 ]]; then
      match=0
      for s in "${allowed_sessions[@]}"; do
        if [[ "$SES" == "$(echo "$s" | xargs)" ]]; then match=1; break; fi
      done
      [[ "$match" -eq 1 ]] || continue
    fi

    resampled_img="${WORK_DIR}/${CANON_BASE}_res-${res}.nii.gz"
    if [[ ! -f "$resampled_img" ]]; then
      ResampleImageBySpacing 3 "$f" "$resampled_img" "$res" "$res" "$res" 0
    fi
    inputs+=("$resampled_img")
  done

  if [[ ${#inputs[@]} -eq 0 ]]; then
    log_warn "No inputs for ${res} mm. Exit."; exit 0
  fi

  # Param calc
  test_img="${inputs[0]}"
  dims=($(mrinfo -size "$test_img"))
  spacing=($(mrinfo -spacing "$test_img"))
  fov_x=$(echo "${dims[0]} * ${spacing[0]}" | bc -l)
  fov_y=$(echo "${dims[1]} * ${spacing[1]}" | bc -l)
  fov_z=$(echo "${dims[2]} * ${spacing[2]}" | bc -l)
  FOV_MAX=$(printf "%.2f\n" $(echo "$fov_x $fov_y $fov_z" | tr ' ' '\n' | sort -nr | head -n1))

  GEN_PARAMS=$(python3 "$ANTS_GEN_ITER" --min "$res" --max "$FOV_MAX" --step-size 1 --output modelbuild | tr -d '\\')
  readarray -t PARAM_ARRAY <<< "$GEN_PARAMS"
  
  cd "$WORK_DIR"
  cmd=(
    antsMultivariateTemplateConstruction2.sh -d 3 -o "${session_group}_${contrast}_"
    -i "$nIter" -g 0.1 -c 2 -j "$nThreads" -k 1 -w 1 -n 0 -r 1
  )
  [[ -n "${PARAM_ARRAY[0]:-}" ]] && cmd+=("${PARAM_ARRAY[0]}")
  [[ -n "${PARAM_ARRAY[1]:-}" ]] && cmd+=("${PARAM_ARRAY[1]}")
  [[ -n "${PARAM_ARRAY[2]:-}" ]] && cmd+=("${PARAM_ARRAY[2]}")

  REF_TEMPLATE=""
  if [[ -z "$prev_template" ]]; then
    [[ -f "$ALLEN_REF_TEMPLATE" ]] && REF_TEMPLATE="$ALLEN_REF_TEMPLATE"
  else
    [[ -f "$prev_template" ]] && REF_TEMPLATE="$prev_template"
  fi

  if [[ -n "$REF_TEMPLATE" ]]; then
    REF_RESAMPLED="${WORK_DIR}/ref_template_res-${res}.nii.gz"
    if [[ ! -f "$REF_RESAMPLED" ]]; then
      ResampleImageBySpacing 3 "$REF_TEMPLATE" "$REF_RESAMPLED" "$res" "$res" "$res" 0
    fi
    cmd+=(-z "$REF_RESAMPLED")
  fi

  log_info "Build ${res} mm..."
  "${cmd[@]}" "${inputs[@]}"

  NEW_TEMPLATE="${WORK_DIR}/${session_group}_${contrast}_template0.nii.gz"
  
  # Final rename to remove "template0"
  CLEAN_NAME="${WORK_DIR}/${session_group}_${contrast}_template.nii.gz"
  mv "$NEW_TEMPLATE" "$CLEAN_NAME"
  NEW_TEMPLATE="$CLEAN_NAME"

  # Optional final regrid to Allen exactly at 0.1
  if [[ "$res" == "0.1" && "${FORCE_ALLEN_GRID:-1}" == "1" && -f "$ALLEN_REF_TEMPLATE" ]]; then
    antsApplyTransforms -d 3 -i "$NEW_TEMPLATE" -r "$ALLEN_REF_TEMPLATE" -o "${NEW_TEMPLATE%.nii.gz}_tmp.nii.gz" -n Linear -t identity
    mv "${NEW_TEMPLATE%.nii.gz}_tmp.nii.gz" "$NEW_TEMPLATE"
  fi

  prev_template="$NEW_TEMPLATE"
done

log_ok "Template ready: $FINAL_TEMPLATE"