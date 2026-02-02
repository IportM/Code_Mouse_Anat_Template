#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================================
# Mouse_Anat_Template.sh
# Driver pipeline (CORRECTED: Early Session Filtering)
# ============================================================

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <BIDS_ROOT | sub-XX> [--out OUT_ROOT]
                 [--modalities "T1map,UNIT1"]
                 [--sessions "ses-1,ses-2"]
                 [--group-name "study"]
                 [--stop-after-allen]
                 [--force-template-single]
                 [--no-allen-ref]
                 [--rare-transform a|s]
                 [--skip-roi]
                 [--force]
                 [--keep-all-rare]
                 [--require-all-modalities]
EOF
  exit 1
}

# ------------------------
# Helpers
# ------------------------
echo_hr() { echo "--------------------------------------------"; }

find_first_existing() {
  for pattern in "$@"; do
    # shellcheck disable=SC2086
    local matches=( $pattern )
    if [[ ${#matches[@]} -gt 0 ]]; then echo "${matches[0]}"; return 0; fi
  done
  return 1
}

basename_nii() {
  local f="$(basename "$1")"
  if [[ "$f" == *.nii.gz ]]; then echo "${f%.nii.gz}"; elif [[ "$f" == *.nii ]]; then echo "${f%.nii}"; else echo "$f"; fi
}

allen_id_from_path() {
  local b="$(basename "$1")"
  b="${b%.nii.gz}"; b="${b%.nii}"; echo "$b"
}

case_id_from_base() {
  local base="$1"
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then echo "${BASH_REMATCH[1]}_ses-${BASH_REMATCH[2]}"; return 0; fi
  if [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then echo "${BASH_REMATCH[1]}_ses-1"; return 0; fi
  return 1
}

rare_allen_outputs_ready() {
  local rare_dir="${brain_extracted_root}/RARE"
  local tdir="${rare_dir}/transforms"
  local adir="${rare_dir}/aligned"

  if [[ ! -d "$tdir" || ! -d "$adir" ]]; then return 1; fi
  local inputs=( "${rare_dir}"/*_RARE_brain_extracted.nii.gz "${rare_dir}"/*_RARE_brain_extracted.nii )
  if [[ ${#inputs[@]} -eq 0 ]]; then return 1; fi

  local n_checked=0
  for f in "${inputs[@]}"; do
    if [[ ! -f "$f" ]]; then continue; fi
    local base case_id
    base="$(basename_nii "$f")"
    case_id="$(case_id_from_base "$base" || true)"
    if [[ -z "$case_id" ]]; then continue; fi

    # Check filter logic here too (implicit via file existence, but safe to keep)
    if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
      if [[ -z "${SELECTED_CASES[$case_id]+x}" ]]; then continue; fi
    fi
    n_checked=$((n_checked+1))

    local affine="${tdir}/${base}_aligned_to_${ALLEN_ID}_0GenericAffine.mat"
    if [[ ! -f "$affine" ]]; then return 1; fi
    if [[ "$RARE_TRANSFORM_TYPE" == "s" ]]; then
      local warp="${tdir}/${base}_aligned_to_${ALLEN_ID}_1Warp.nii.gz"
      if [[ ! -f "$warp" ]]; then return 1; fi
    fi
  done
  if [[ "$n_checked" -eq 0 ]]; then return 1; fi
  return 0
}

roi_tables_exist_for_group() {
  local group_name="$1"; shift
  local modalities=( "$@" )
  for m in "${modalities[@]}"; do
    local tsv="${OUT_ROOT}/derivatives/ROI_stats/${group_name}/${group_name}_${m}_roi_stats.tsv"
    if [[ ! -f "$tsv" ]]; then return 1; fi
  done
  return 0
}

# ------------------------
# Args & Defaults
# ------------------------
if [[ $# -lt 1 ]]; then usage; fi
INPUT_PATH="${1%/}"; shift

OUT_ROOT=""
STOP_AFTER_ALLEN=0
FORCE_TEMPLATE_SINGLE=0
USE_ALLEN_REF=1
RARE_TRANSFORM_TYPE="a"
SKIP_ROI=0
FORCE_RERUN=0
MODALITIES_LIST="T1map,UNIT1"
FILTER_BY_MODALITIES=1
REQUIRE_ALL_MODALITIES=0
SESSION_FILTER=""
TEMPLATE_GROUP_NAME="study"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_ROOT="${2:-}"; shift 2 ;;
    --modalities) MODALITIES_LIST="${2:-}"; shift 2 ;;
    --sessions) SESSION_FILTER="${2:-}"; shift 2 ;;
    --group-name) TEMPLATE_GROUP_NAME="${2:-study}"; shift 2 ;;
    --stop-after-allen) STOP_AFTER_ALLEN=1; shift ;;
    --force-template-single) FORCE_TEMPLATE_SINGLE=1; shift ;;
    --no-allen-ref) USE_ALLEN_REF=0; shift ;;
    --rare-transform) RARE_TRANSFORM_TYPE="${2:-s}"; shift 2 ;;
    --skip-roi) SKIP_ROI=1; shift ;;
    --force) FORCE_RERUN=1; shift ;;
    --keep-all-rare) FILTER_BY_MODALITIES=0; shift ;;
    --require-all-modalities) REQUIRE_ALL_MODALITIES=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

requested_modalities=()
if [[ -n "${MODALITIES_LIST// /}" ]]; then
  IFS=',' read -r -a requested_modalities <<< "$MODALITIES_LIST"
  tmp=()
  for m in "${requested_modalities[@]}"; do
    m="$(echo "$m" | tr -d ' ' )"; [[ -n "$m" ]] || continue; [[ "$m" == "RARE" ]] && continue; tmp+=( "$m" )
  done
  requested_modalities=( "${tmp[@]}" )
fi

if [[ "$(basename "$INPUT_PATH")" == sub-* ]]; then
  BIDS_DIR="$(dirname "$INPUT_PATH")"
  subject_dirs=( "$INPUT_PATH" )
else
  BIDS_DIR="$INPUT_PATH"
  subject_dirs=( "$BIDS_DIR"/sub-* )
fi

[[ -d "$BIDS_DIR" ]] || { echo "ERROR: BIDS dir not found: $BIDS_DIR"; exit 1; }
[[ ${#subject_dirs[@]} -gt 0 ]] || { echo "ERROR: No sub-* found in $BIDS_DIR"; exit 1; }

N_SUBJECTS="${#subject_dirs[@]}"
if [[ -z "${OUT_ROOT}" ]]; then OUT_ROOT="$(pwd)/BIDS_driver_output"; fi
mkdir -p "$OUT_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

CREATE_MASK_SCRIPT="${CREATE_MASK_SCRIPT:-$SCRIPT_DIR/Create_Masks.py}"
MASK_APPLY_SCRIPT="${MASK_APPLY_SCRIPT:-$SCRIPT_DIR/mask_apply.py}"
RARE_ALIGN_SCRIPT="${RARE_ALIGN_SCRIPT:-$SCRIPT_DIR/Rare_alignment.sh}"
ALIGN_SCRIPT="${ALIGN_SCRIPT:-$SCRIPT_DIR/Align.sh}"
RARE_TEMPLATE_SCRIPT="${RARE_TEMPLATE_SCRIPT:-$SCRIPT_DIR/Rare_Template.sh}"
APPLY_TO_TEMPLATE_SCRIPT="${APPLY_TO_TEMPLATE_SCRIPT:-$SCRIPT_DIR/Apply_to_Template.sh}"
MAKE_TEMPLATE_SCRIPT="${MAKE_TEMPLATE_SCRIPT:-$SCRIPT_DIR/Make_Template.sh}"
ROI_SCRIPT="${ROI_SCRIPT:-$SCRIPT_DIR/Graph_1ROI.py}"

ALLEN_TEMPLATE_DEFAULT="$SCRIPT_DIR/resources/100_AMBA_ref.nii.gz"
if [[ ! -f "$ALLEN_TEMPLATE_DEFAULT" ]]; then
  ALLEN_TEMPLATE_DEFAULT="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/Allen/LR/100_AMBA_ref.nii.gz"
fi
ALLEN_TEMPLATE="${ALLEN_TEMPLATE:-$ALLEN_TEMPLATE_DEFAULT}"
ALLEN_LABELS="${ALLEN_LABELS:-$SCRIPT_DIR/resources/100_AMBA_LR.nii.gz}"
ALLEN_LABELS_TABLE="${ALLEN_LABELS_TABLE:-$SCRIPT_DIR/resources/allen_labels_table.csv}"

if [[ ! -f "$CREATE_MASK_SCRIPT" ]]; then echo "ERROR: Create_Masks.py not found"; exit 1; fi
if [[ ! -f "$MASK_APPLY_SCRIPT" ]]; then echo "ERROR: mask_apply.py not found"; exit 1; fi
if [[ ! -f "$ALLEN_TEMPLATE" ]]; then echo "ERROR: ALLEN_TEMPLATE not found"; exit 1; fi
if [[ ! -f "$RARE_ALIGN_SCRIPT" ]]; then echo "ERROR: Rare_alignment.sh not found"; exit 1; fi
if [[ ! -f "$ALIGN_SCRIPT" ]]; then echo "ERROR: Align.sh not found"; exit 1; fi

ALLEN_ID="$(allen_id_from_path "$ALLEN_TEMPLATE")"

echo "BIDS_DIR             : $BIDS_DIR"
echo "OUT_ROOT             : $OUT_ROOT"
echo "TEMPLATE_GROUP_NAME  : $TEMPLATE_GROUP_NAME"
echo "SESSION_FILTER       : ${SESSION_FILTER:-<ALL>}"
echo "FORCE_RERUN          : $FORCE_RERUN"
echo_hr

declare -A SELECTED_CASES=()
DO_TEMPLATE_STEPS=1
if [[ "$N_SUBJECTS" -lt 2 && "$FORCE_TEMPLATE_SINGLE" != "1" ]]; then
  echo " Single-subject dataset. Template steps skipped."
  DO_TEMPLATE_STEPS=0
fi
declare -A modality_found=()

# ============================================================
# STEP 1-3: Masks & Extract
# ============================================================
brain_extracted_root="${OUT_ROOT}/derivatives/Brain_extracted"
mkdir -p "${brain_extracted_root}/RARE"

# Prepare Session Filter array
filter_sessions=()
if [[ -n "$SESSION_FILTER" ]]; then
  IFS=',' read -r -a filter_sessions <<< "$SESSION_FILTER"
fi

for sub_dir in "${subject_dirs[@]}"; do
  [[ -d "$sub_dir" ]] || continue
  sub="$(basename "$sub_dir")"
  ses_dirs=( "$sub_dir"/ses-* )
  if [[ ${#ses_dirs[@]} -eq 0 ]]; then ses_dirs=( "$sub_dir" ); fi

  for ses_dir in "${ses_dirs[@]}"; do
    [[ -d "$ses_dir" ]] || continue
    
    if [[ "$(basename "$ses_dir")" == ses-* ]]; then
      ses_tag="$(basename "$ses_dir")"
      prefix="${sub}_${ses_tag}"
      assume_ses1=0
      out_rel_anat="${sub}/${ses_tag}/anat"
      ses_canon="$ses_tag"
    else
      ses_tag=""
      prefix="${sub}"
      assume_ses1=1
      out_rel_anat="${sub}/ses-1/anat"
      ses_canon="ses-1"
    fi

    # === FIX: EARLY SESSION FILTERING ===
    if [[ ${#filter_sessions[@]} -gt 0 ]]; then
      match=0
      for s in "${filter_sessions[@]}"; do
        # We compare ses_tag (e.g. "ses-1") with filter item
        if [[ "$ses_tag" == "$(echo "$s" | xargs)" ]]; then match=1; break; fi
        # Fallback if no session in BIDS but user asked "ses-1" (assume match if ses_canon matches)
        if [[ "$ses_canon" == "$(echo "$s" | xargs)" ]]; then match=1; break; fi
      done
      
      if [[ "$match" -eq 0 ]]; then 
        # Skip silently to avoid log spam, or uncomment below:
        # echo "Skipping $sub $ses_tag (not in filter)"
        continue 
      fi
    fi
    # ====================================

    case_id="${sub}_${ses_canon}"
    anat_dir="$ses_dir/anat"
    [[ -d "$anat_dir" ]] || continue

    rare="$(find_first_existing "${anat_dir}/${prefix}"*RARE*.nii.gz "${anat_dir}/${prefix}"*RARE*.nii)" || rare=""
    if [[ -z "$rare" ]]; then continue; fi

    declare -A SESSION_MOD_PATH=()
    found_any=0; missing_any=0
    if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
      for mod in "${requested_modalities[@]}"; do
        img="$(find_first_existing "${anat_dir}/${prefix}"*"${mod}"*.nii.gz "${anat_dir}/${prefix}"*"${mod}"*.nii)" || img=""
        if [[ -n "$img" ]]; then SESSION_MOD_PATH["$mod"]="$img"; found_any=1; else missing_any=1; fi
      done
      if [[ "$REQUIRE_ALL_MODALITIES" == "1" && "$missing_any" == "1" ]]; then continue; fi
      if [[ "$found_any" == "0" ]]; then continue; fi
    fi

    echo "[OK]   $case_id : $rare"
    SELECTED_CASES["$case_id"]=1
    rare_base="$(basename_nii "$rare")"
    mask_path="${OUT_ROOT}/derivatives/${out_rel_anat}/${rare_base}_mask_final.nii.gz"
    
    if [[ "$FORCE_RERUN" != "1" && -f "$mask_path" ]]; then :
    else
      "$PYTHON_BIN" "$CREATE_MASK_SCRIPT" --input "$rare" --bids-root "$BIDS_DIR" --out-root "$OUT_ROOT"
    fi

    if [[ ! -f "$mask_path" ]]; then continue; fi

    for mod in "${requested_modalities[@]}"; do
      img="${SESSION_MOD_PATH[$mod]:-}"
      [[ -z "$img" ]] && continue
      mkdir -p "${brain_extracted_root}/${mod}"
      img_base="$(basename_nii "$img")"
      if [[ "$assume_ses1" == "1" ]]; then
         if [[ "$img_base" =~ ^(sub-[^_]+)_(.+)$ ]]; then img_base="${BASH_REMATCH[1]}_ses-1_${BASH_REMATCH[2]}"; fi
      fi
      out_img="${brain_extracted_root}/${mod}/${img_base}_brain_extracted.nii.gz"
      if [[ ! -f "$out_img" || "$FORCE_RERUN" == "1" ]]; then
        "$PYTHON_BIN" "$MASK_APPLY_SCRIPT" --mask "$mask_path" --acq "$img" --output "$out_img"
      fi
      modality_found["$mod"]=1
    done
  done
done
echo_hr

# ============================================================
# STEP 4: Align RARE -> Allen
# ============================================================
echo "=== Align RARE to Allen ==="
if [[ "$FORCE_RERUN" != "1" ]] && rare_allen_outputs_ready; then
  echo " RARE alignment already done."
else
  export BIDS_DIR="$OUT_ROOT"
  export BRAIN_EXTRACTED_DIR="$OUT_ROOT/derivatives/Brain_extracted"
  export ALLEN_TEMPLATE="$ALLEN_TEMPLATE"
  export TRANSFORM_TYPE="$RARE_TRANSFORM_TYPE"
  bash "$RARE_ALIGN_SCRIPT"
fi
echo_hr

# ============================================================
# STEP 5: Align OPTIONAL -> Allen
# ============================================================
echo "=== Align optional modalities to Allen ==="
mods_to_align=()
for m in "${requested_modalities[@]}"; do [[ -n "${modality_found[$m]+x}" ]] && mods_to_align+=( "$m" ); done

if [[ ${#mods_to_align[@]} -gt 0 ]]; then
  export BRAIN_DIR="${brain_extracted_root}"
  export TRANSFORM_DIR="${brain_extracted_root}/RARE/transforms"
  export ALLEN_TEMPLATE="$ALLEN_TEMPLATE"
  export INTERP="BSpline[3]"
  export FORCE_RERUN="$FORCE_RERUN"
  bash "$ALIGN_SCRIPT"
else
  echo " No optional modalities to align."
fi
echo_hr

if [[ "$STOP_AFTER_ALLEN" == "1" ]]; then exit 0; fi

# ============================================================
# STEP 6: Build RARE template
# ============================================================
if [[ "$DO_TEMPLATE_STEPS" == "1" ]]; then
  echo "=== Build RARE template (Group: $TEMPLATE_GROUP_NAME) ==="
  export BRAIN_EXTRACTED_DIR="${brain_extracted_root}"
  export USE_ALLEN_REF="$USE_ALLEN_REF"
  export ALLEN_REF_TEMPLATE="$ALLEN_TEMPLATE"
  export INPUT_MODE="auto"
  
  bash "$RARE_TEMPLATE_SCRIPT" "RARE" "$TEMPLATE_GROUP_NAME" "$SESSION_FILTER"
  echo_hr

  # ============================================================
  # STEP 7: Apply to Template + Average
  # ============================================================
  if [[ ${#mods_to_align[@]} -gt 0 ]]; then
    for m in "${mods_to_align[@]}"; do
      echo "=== Modality to template: $m ==="
      if [[ -f "$APPLY_TO_TEMPLATE_SCRIPT" ]]; then
        export TARGET_GROUP="$TEMPLATE_GROUP_NAME"
        export INPUT_MODE="allen"
        export INTERP="BSpline[3]"
        bash "$APPLY_TO_TEMPLATE_SCRIPT" "$m"
      fi
      if [[ -f "$MAKE_TEMPLATE_SCRIPT" ]]; then
        export BRAIN_EXTRACTED_DIR="${brain_extracted_root}"
        bash "$MAKE_TEMPLATE_SCRIPT" "$m"
      fi
      echo_hr
    done
  fi
else
  echo "=== Template steps skipped (single subject) ==="
fi

# ============================================================
# STEP 8: ROI extraction
# ============================================================
if [[ "$SKIP_ROI" == "1" ]]; then exit 0; fi

if [[ "$FORCE_RERUN" != "1" ]]; then
  if roi_tables_exist_for_group "$TEMPLATE_GROUP_NAME" "${mods_to_align[@]}"; then
    echo " ROI tables already exist. Done."
    exit 0
  fi
fi

if [[ ${#mods_to_align[@]} -gt 0 && -f "$ROI_SCRIPT" ]]; then
  echo "=== Extract ROI stats ==="
  roi_modalities="$(IFS=','; echo "${mods_to_align[*]}")"
  "$PYTHON_BIN" "$ROI_SCRIPT" \
    --out-root "$OUT_ROOT" \
    --labels "$ALLEN_LABELS" \
    --labels-table "$ALLEN_LABELS_TABLE" \
    --modalities "$roi_modalities" \
    --per-roi-png \
    --roi-ids all
fi
echo " Done."