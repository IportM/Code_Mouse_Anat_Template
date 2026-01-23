#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================================
# Mouse_Anat_Template.sh
#
# Driver pipeline (high-level):
#   1) Find RARE in BIDS (required) for each subject/session
#   2) Create brain mask from RARE + write RARE brain_extracted
#   3) Apply that mask to any user-requested anatomical modalities (OPTIONAL),
#      producing derivatives/Brain_extracted/<MOD>/*_brain_extracted.nii.gz
#   4) Align RARE brain_extracted -> Allen (antsRegistrationSyN.sh via Rare_alignement.sh)
#   5) Align the other modalities -> Allen (apply RARE->Allen transforms)
#   6) (Optional) Build RARE template(s) per group (S01/S02/S03)
#   7) (Optional) Apply RARE-template transforms to modalities + compute avg templates
#   8) (Optional) ROI stats extraction (Graph_1ROI.py)
#
# Special handling:
#   - If input has ONLY ONE subject (and not forced):
#       -> skip template steps (6/7),
#       -> but STILL RUN ROI extraction by generating "avg" images in Allen space
#          from alignedSyN_Allen outputs (AverageImages).
#   - If input path is a single sub-XX folder => supported
#   - If dataset has NO sessions => assume ses-1 for canonical outputs
#
# Caching / reruns:
#   - Every step checks if its final outputs already exist; if yes, skip to the next step.
#   - Use --force to recompute / overwrite where applicable.
#
# IMPORTANT (requested):
#   - RARE stays mandatory
#   - Other modalities are OPTIONAL (--modalities)
#   - FILTERING: only keep RARE for (sub,ses) where requested modalities exist
#     (require ANY by default, or ALL with --require-all-modalities)
# ============================================================

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <BIDS_ROOT | sub-XX> [--out OUT_ROOT]
                 [--modalities "T1map,UNIT1"]    # optional modalities (RARE always required)
                 [--stop-after-allen]
                 [--force-template-single]
                 [--no-allen-ref]
                 [--rare-transform a|s]
                 [--skip-roi]
                 [--force]
                 [--keep-all-rare]
                 [--require-all-modalities]

Filtering behavior (default):
  - RARE is always required.
  - If --modalities is non-empty:
      Only keep sessions (sub,ses) where at least ONE requested modality exists.
  - Use --require-all-modalities to require ALL requested modalities.
  - Use --keep-all-rare to disable filtering (keep all RARE even if modalities missing).

Single-subject behavior:
  - If only ONE subject is detected (and not --force-template-single):
      Skip template steps, but still do ROI extraction using Allen-space averages.

Caching:
  - If outputs exist, steps are skipped automatically.
  - Use --force to recompute/overwrite outputs.

EOF
  exit 1
}

# ------------------------
# Helpers
# ------------------------
echo_hr() { echo "--------------------------------------------"; }

run_optional() {
  set +e
  "$@"
  local rc=$?
  set -e
  return $rc
}

find_first_existing() {
  for pattern in "$@"; do
    # shellcheck disable=SC2086
    local matches=( $pattern )
    if [[ ${#matches[@]} -gt 0 ]]; then
      echo "${matches[0]}"
      return 0
    fi
  done
  return 1
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

# Insert "_ses-1_" after "sub-XX_" if base doesn't contain "_ses-"
canon_add_ses1_if_missing() {
  local base="$1"
  if [[ "$base" == *"_ses-"* ]]; then
    echo "$base"
    return 0
  fi
  if [[ "$base" =~ ^(sub-[^_]+)_(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}_ses-1_${BASH_REMATCH[2]}"
    return 0
  fi
  echo "$base"
}

allen_id_from_path() {
  local p="$1"
  local b
  b="$(basename "$p")"
  b="${b%.nii.gz}"
  b="${b%.nii}"
  echo "$b"
}

group_from_sesnum() {
  local sesnum="$1"
  if [[ "$sesnum" == "1" || "$sesnum" == "2" ]]; then echo "S01"
  elif [[ "$sesnum" == "3" || "$sesnum" == "4" ]]; then echo "S02"
  elif [[ "$sesnum" == "5" || "$sesnum" == "6" ]]; then echo "S03"
  else echo "" ; fi
}

# Extract canonical case_id sub-XX_ses-Y from a brain_extracted basename
# Supports:
#   sub-14_ses-3_RARE_brain_extracted
#   sub-14_RARE_brain_extracted  -> assumes ses-1
case_id_from_base() {
  local base="$1"
  if [[ "$base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}_ses-${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}_ses-1"
    return 0
  fi
  return 1
}

detect_groups_from_rare_inputs() {
  local groups=()
  declare -A seen=()

  local rare_files=( "${brain_extracted_root}/RARE"/*_RARE_brain_extracted.nii.gz "${brain_extracted_root}/RARE"/*_RARE_brain_extracted.nii )
  for f in "${rare_files[@]}"; do
    [[ -f "$f" ]] || continue
    local b sesnum g case_id
    b="$(basename_nii "$f")"

    case_id="$(case_id_from_base "$b" || true)"
    [[ -n "$case_id" ]] || continue

    # filter to selected cases (when enabled)
    if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
      [[ -n "${SELECTED_CASES[$case_id]+x}" ]] || continue
    fi

    if [[ "$b" =~ _ses-([0-9]+)_ ]]; then
      sesnum="${BASH_REMATCH[1]}"
    else
      sesnum="1"
    fi
    g="$(group_from_sesnum "$sesnum")"
    [[ -n "$g" ]] || g="S01"

    if [[ -z "${seen[$g]+x}" ]]; then
      groups+=( "$g" )
      seen["$g"]=1
    fi
  done

  if [[ ${#groups[@]} -eq 0 ]]; then
    groups=( "S01" )
  fi

  echo "${groups[*]}"
}

# Build "avg" images in Allen space for ROI extraction (single-subject mode).
# Output structure matches discover_templates() in Graph_1ROI.py:
#   OUT_ROOT/derivatives/Brain_extracted/<MOD>/To_Template/SyN/<GROUP>/template/<GROUP>_<MOD>_avg.nii.gz
build_allen_space_avgs_for_roi() {
  local mod="$1"
  local in_dir="${brain_extracted_root}/${mod}/aligned"
  [[ -d "$in_dir" ]] || { echo "â†’ [single-subject] [$mod] missing aligned: $in_dir (skip)"; return 0; }

  local files=( "${in_dir}"/*.nii.gz "${in_dir}"/*.nii )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "â†’ [single-subject] [$mod] no Allen-aligned files in $in_dir (skip)"
    return 0
  fi

  for g in S01 S02 S03; do
    local imgs=()
    for f in "${files[@]}"; do
      [[ -f "$f" ]] || continue
      local b sesnum gg case_id
      b="$(basename_nii "$f")"

      case_id="$(case_id_from_base "$b" || true)"
      [[ -n "$case_id" ]] || continue

      # filter to selected cases (when enabled)
      if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
        [[ -n "${SELECTED_CASES[$case_id]+x}" ]] || continue
      fi

      if [[ "$b" =~ _ses-([0-9]+)_ ]]; then
        sesnum="${BASH_REMATCH[1]}"
      else
        sesnum="1"
      fi
      gg="$(group_from_sesnum "$sesnum")"
      [[ -n "$gg" ]] || gg="S01"
      [[ "$gg" == "$g" ]] || continue

      imgs+=( "$f" )
    done

    [[ ${#imgs[@]} -gt 0 ]] || continue

    local out_dir="${brain_extracted_root}/${mod}/To_Template/${g}/template"
    mkdir -p "$out_dir"
    local out_avg="${out_dir}/${g}_${mod}_avg.nii.gz"

    if [[ -f "$out_avg" && "$FORCE_RERUN" != "1" ]]; then
      echo "â†’ [single-subject] avg exists: $out_avg (skip)"
      continue
    fi

    echo "â†’ [single-subject] Building Allen-space avg: $out_avg (${#imgs[@]} input(s))"
    AverageImages 3 "$out_avg" 0 "${imgs[@]}"
  done
}

# Return 0 if ALL expected RARE->Allen outputs exist (for SELECTED cases if filtering is enabled)
rare_allen_outputs_ready() {
  local rare_dir="${brain_extracted_root}/RARE"
  local tdir="${rare_dir}/matrice_transforms"
  local adir="${rare_dir}/aligned"

  [[ -d "$tdir" && -d "$adir" ]] || return 1

  local inputs=( "${rare_dir}"/*_RARE_brain_extracted.nii.gz "${rare_dir}"/*_RARE_brain_extracted.nii )
  [[ ${#inputs[@]} -gt 0 ]] || return 1

  local n_checked=0
  for f in "${inputs[@]}"; do
    [[ -f "$f" ]] || continue
    local base case_id
    base="$(basename_nii "$f")"

    case_id="$(case_id_from_base "$base" || true)"
    [[ -n "$case_id" ]] || continue

    # filter to selected cases only (when enabled)
    if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
      [[ -n "${SELECTED_CASES[$case_id]+x}" ]] || continue
    fi

    n_checked=$((n_checked+1))

    local affine="${tdir}/${base}_aligned_to_${ALLEN_ID}_0GenericAffine.mat"
    [[ -f "$affine" ]] || return 1

    if [[ "$RARE_TRANSFORM_TYPE" == "s" ]]; then
      local warp="${tdir}/${base}_aligned_to_${ALLEN_ID}_1Warp.nii.gz"
      [[ -f "$warp" ]] || return 1
    fi

    local aligned_hits=( "${adir}/${base}"*"_aligned_to_${ALLEN_ID}"*.nii.gz "${adir}/${base}"*"_aligned_to_${ALLEN_ID}"*.nii )
    [[ ${#aligned_hits[@]} -gt 0 ]] || return 1
  done

  [[ "$n_checked" -gt 0 ]] || return 1
  return 0
}

# Check whether all expected modality "avg" templates exist for a modality and a set of groups
modality_all_group_avgs_exist() {
  local mod="$1"; shift
  local groups=( "$@" )
  local ok=1
  for g in "${groups[@]}"; do
    local avg="${brain_extracted_root}/${mod}/To_Template/${g}/template/${g}_${mod}_avg.nii.gz"
    if [[ ! -f "$avg" ]]; then
      ok=0
      break
    fi
  done
  [[ "$ok" -eq 1 ]]
}

# Compute missing modality averages in template space (caching-aware)
# Inputs expected under:
#   Brain_extracted/<MOD>/To_Template/SyN/<GROUP>/*_in_template.nii.gz
# Output:
#   .../To_Template/SyN/<GROUP>/template/<GROUP>_<MOD>_avg.nii.gz
compute_modality_template_avgs() {
  local mod="$1"; shift
  local groups=( "$@" )

  for g in "${groups[@]}"; do
    local out_dir="${brain_extracted_root}/${mod}/To_Template/${g}/template"
    mkdir -p "$out_dir"
    local out_avg="${out_dir}/${g}_${mod}_template.nii.gz"

    if [[ -f "$out_avg" && "$FORCE_RERUN" != "1" ]]; then
      echo "â†’ [$mod] avg exists: $out_avg (skip)"
      continue
    fi

    local in_dir="${brain_extracted_root}/${mod}/To_Template/${g}"
    [[ -d "$in_dir" ]] || { echo "â†’ [$mod] missing in_template dir: $in_dir (skip avg)"; continue; }

    local maps=( "${in_dir}"/*_in_template.nii.gz "${in_dir}"/*_in_template.nii )
    if [[ ${#maps[@]} -eq 0 ]]; then
      echo "â†’ [$mod] no *_in_template files for $g (skip avg)"
      continue
    fi

    echo "â†’ [$mod] AverageImages ($g): ${#maps[@]} file(s) -> $out_avg"
    AverageImages 3 "$out_avg" 0 "${maps[@]}"
  done
}

# Decide if ROI extraction can be skipped (TSV exists for all groupÃ—modality)
roi_tables_exist_for_all() {
  local modalities=( "$@" )
  local groups=( ${GROUPS_NEEDED} )

  for g in "${groups[@]}"; do
    for m in "${modalities[@]}"; do
      local tsv="${OUT_ROOT}/derivatives/ROI_stats/${g}/${g}_${m}_roi_stats.tsv"
      local csv="${OUT_ROOT}/derivatives/ROI_stats/${g}/${g}_${m}_roi_stats.csv"
      if [[ ! -f "$tsv" && ! -f "$csv" ]]; then
        return 1
      fi
    done
  done
  return 0
}

# ------------------------
# Args
# ------------------------
[[ $# -ge 1 ]] || usage
INPUT_PATH="${1%/}"; shift

OUT_ROOT=""
STOP_AFTER_ALLEN=0
FORCE_TEMPLATE_SINGLE=0
USE_ALLEN_REF=1
RARE_TRANSFORM_TYPE="a"
SKIP_ROI=0
FORCE_RERUN=0

# Optional modalities (NOT including RARE)
MODALITIES_LIST="T1map,UNIT1"

# Filtering behavior (requested)
FILTER_BY_MODALITIES=1
REQUIRE_ALL_MODALITIES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_ROOT="${2:-}"; shift 2 ;;
    --modalities) MODALITIES_LIST="${2:-}"; shift 2 ;;
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

if [[ "$RARE_TRANSFORM_TYPE" != "a" && "$RARE_TRANSFORM_TYPE" != "s" ]]; then
  echo "ERROR: --rare-transform must be 'a' or 's' (got: $RARE_TRANSFORM_TYPE)"
  exit 1
fi

# Parse modalities list into array (ignore empty)
requested_modalities=()
if [[ -n "${MODALITIES_LIST// /}" ]]; then
  IFS=',' read -r -a requested_modalities <<< "$MODALITIES_LIST"
  tmp=()
  for m in "${requested_modalities[@]}"; do
    m="$(echo "$m" | tr -d ' ' )"
    [[ -n "$m" ]] || continue
    [[ "$m" == "RARE" ]] && continue
    tmp+=( "$m" )
  done
  requested_modalities=( "${tmp[@]}" )
fi

# ------------------------
# Resolve BIDS root + subject list (supports passing sub-XX directly)
# ------------------------
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

# OUT_ROOT default
if [[ -z "${OUT_ROOT}" ]]; then
  OUT_ROOT="$(pwd)/BIDS_driver_output"
fi
mkdir -p "$OUT_ROOT"

# ------------------------
# Script paths (defaults: same folder as driver)
# ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON_BIN="${PYTHON_BIN:-python3}"
CREATE_MASK_SCRIPT="${CREATE_MASK_SCRIPT:-$SCRIPT_DIR/Create_Masks.py}"
MASK_APPLY_SCRIPT="${MASK_APPLY_SCRIPT:-$SCRIPT_DIR/mask_apply.py}"

RARE_ALIGN_SCRIPT="${RARE_ALIGN_SCRIPT:-$SCRIPT_DIR/Rare_alignement.sh}"
RARE_TEMPLATE_SCRIPT="${RARE_TEMPLATE_SCRIPT:-$SCRIPT_DIR/Rare_Template.sh}"
APPLY_TO_TEMPLATE_SCRIPT="${APPLY_TO_TEMPLATE_SCRIPT:-$SCRIPT_DIR/Apply_to_Template.sh}"
ROI_SCRIPT="${ROI_SCRIPT:-$SCRIPT_DIR/Graph_1ROI.py}"

# Allen paths
ALLEN_TEMPLATE_DEFAULT="$SCRIPT_DIR/100_AMBA_ref.nii.gz"
if [[ ! -f "$ALLEN_TEMPLATE_DEFAULT" ]]; then
  ALLEN_TEMPLATE_DEFAULT="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/Allen/LR/100_AMBA_ref.nii.gz"
fi
ALLEN_TEMPLATE="${ALLEN_TEMPLATE:-$ALLEN_TEMPLATE_DEFAULT}"

ALLEN_LABELS_DEFAULT="$SCRIPT_DIR/Ressources/100_AMBA_LR.nii.gz"
ALLEN_LABELS="${ALLEN_LABELS:-$ALLEN_LABELS_DEFAULT}"
ALLEN_LABELS_TABLE_DEFAULT="$SCRIPT_DIR/Ressources/allen_labels_table.csv"
ALLEN_LABELS_TABLE="${ALLEN_LABELS_TABLE:-$ALLEN_LABELS_TABLE_DEFAULT}"

[[ -f "$CREATE_MASK_SCRIPT" ]] || { echo "ERROR: Create_Masks.py not found: $CREATE_MASK_SCRIPT"; exit 1; }
[[ -f "$MASK_APPLY_SCRIPT" ]]  || { echo "ERROR: mask_apply.py not found: $MASK_APPLY_SCRIPT"; exit 1; }
[[ -f "$ALLEN_TEMPLATE" ]]     || { echo "ERROR: ALLEN_TEMPLATE not found: $ALLEN_TEMPLATE"; exit 1; }
[[ -f "$RARE_ALIGN_SCRIPT" ]]  || { echo "ERROR: Rare_alignement.sh not found: $RARE_ALIGN_SCRIPT"; exit 1; }
[[ -f "$RARE_TEMPLATE_SCRIPT" ]] || { echo "ERROR: Rare_Template.sh not found: $RARE_TEMPLATE_SCRIPT"; exit 1; }
[[ -f "$APPLY_TO_TEMPLATE_SCRIPT" ]] || echo "[WARN] Apply_to_Template.sh not found: $APPLY_TO_TEMPLATE_SCRIPT (template-space mapping will be skipped)"
[[ -f "$ROI_SCRIPT" ]] || echo "[WARN] Graph_1ROI.py not found: $ROI_SCRIPT (ROI extraction will be skipped)"

ALLEN_ID="$(allen_id_from_path "$ALLEN_TEMPLATE")"

echo "BIDS_DIR             : $BIDS_DIR"
echo "INPUT_PATH           : $INPUT_PATH"
echo "OUT_ROOT             : $OUT_ROOT"
echo "N_SUBJECTS           : $N_SUBJECTS"
echo "USE_ALLEN_REF        : $USE_ALLEN_REF"
echo "RARE_TRANSFORM_TYPE  : $RARE_TRANSFORM_TYPE"
echo "ALLEN_TEMPLATE       : $ALLEN_TEMPLATE (ID=$ALLEN_ID)"
echo "Modalities requested : ${requested_modalities[*]:-<none>}"
echo "FILTER_BY_MODALITIES : $FILTER_BY_MODALITIES (require_all=$REQUIRE_ALL_MODALITIES)"
echo "FORCE_RERUN          : $FORCE_RERUN"
echo_hr

# Selected cases (canonical): "sub-XX_ses-Y"
declare -A SELECTED_CASES=()

# Auto-skip template when only one subject (unless forced)
DO_TEMPLATE_STEPS=1
if [[ "$N_SUBJECTS" -lt 2 && "$FORCE_TEMPLATE_SINGLE" != "1" ]]; then
  echo "âš ï¸ Single-subject dataset detected (N=$N_SUBJECTS)."
  echo "â†’ Template steps (6/7) will be skipped, but ROI extraction will still run using Allen-space averages."
  DO_TEMPLATE_STEPS=0
fi

# Track which optional modalities were actually found/processed
declare -A modality_found=()

# ============================================================
# STEP 1/2/3: Mask creation (RARE) + mask apply (OPTIONAL modalities)
# ============================================================
brain_extracted_root="${OUT_ROOT}/derivatives/Brain_extracted"
mkdir -p "${brain_extracted_root}/RARE"

for sub_dir in "${subject_dirs[@]}"; do
  [[ -d "$sub_dir" ]] || continue
  sub="$(basename "$sub_dir")"

  ses_dirs=( "$sub_dir"/ses-* )
  if [[ ${#ses_dirs[@]} -eq 0 ]]; then
    ses_dirs=( "$sub_dir" )  # sessionless => treat as ses-1 later
  fi

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

    case_id="${sub}_${ses_canon}"

    anat_dir="$ses_dir/anat"
    if [[ ! -d "$anat_dir" ]]; then
      echo "[WARN] $sub ${ses_tag:+$ses_tag} : missing anat/ -> skip"
      continue
    fi

    # ---- Find RARE (required) ----
    rare="$(find_first_existing \
      "${anat_dir}/${prefix}"*RARE*.nii.gz \
      "${anat_dir}/${prefix}"*RARE*.nii \
      "${anat_dir}/${sub}"*"${ses_tag:+_${ses_tag}}"*RARE*.nii.gz \
      "${anat_dir}/${sub}"*"${ses_tag:+_${ses_tag}}"*RARE*.nii \
    )" || rare=""

    if [[ -z "$rare" ]]; then
      echo "[ERROR] $sub ${ses_tag:+$ses_tag} : RARE not found (required) -> skip"
      continue
    fi

    echo "[OK]   $case_id"
    echo "       RARE : $rare"

    rel_path="${anat_dir#${BIDS_DIR}/}"

    # Pre-scan requested modalities for this (sub,ses) to decide whether we keep this RARE
    declare -A SESSION_MOD_PATH=()
    found_any=0
    missing_any=0

    if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
      for mod in "${requested_modalities[@]}"; do
        img="$(find_first_existing \
          "${anat_dir}/${prefix}"*"${mod}"*.nii.gz \
          "${anat_dir}/${prefix}"*"${mod}"*.nii \
          "${anat_dir}/${sub}"*"${ses_tag:+_${ses_tag}}"*"${mod}"*.nii.gz \
          "${anat_dir}/${sub}"*"${ses_tag:+_${ses_tag}}"*"${mod}"*.nii \
        )" || img=""

        if [[ -n "$img" ]]; then
          SESSION_MOD_PATH["$mod"]="$img"
          found_any=1
        else
          missing_any=1
        fi
      done

      if [[ "$REQUIRE_ALL_MODALITIES" == "1" ]]; then
        if [[ "$missing_any" == "1" ]]; then
          echo "       -> Not all requested modalities present for ${case_id}: skip this session (ignore RARE)."
          echo ""
          continue
        fi
      else
        if [[ "$found_any" == "0" ]]; then
          echo "       -> No requested modalities present for ${case_id}: skip this session (ignore RARE)."
          echo ""
          continue
        fi
      fi
    fi

    # Keep this case
    SELECTED_CASES["$case_id"]=1

    rare_base="$(basename_nii "$rare")"

    mask_src="${OUT_ROOT}/derivatives/${rel_path}/${rare_base}_mask_final.nii.gz"
    mask_dst="${OUT_ROOT}/derivatives/${out_rel_anat}/${rare_base}_mask_final.nii.gz"

    rare_be_src1="${brain_extracted_root}/RARE/${rare_base}_brain_extracted.nii.gz"
    rare_base_canon="$(canon_add_ses1_if_missing "$rare_base")"
    rare_be_src2="${brain_extracted_root}/RARE/${rare_base_canon}_brain_extracted.nii.gz"

    # Decide canonical mask_path (handle sessionless)
    if [[ "$assume_ses1" == "1" ]]; then
      mkdir -p "$(dirname "$mask_dst")"
      if [[ -f "$mask_dst" ]]; then
        mask_path="$mask_dst"
      elif [[ -f "$mask_src" ]]; then
        cp -f "$mask_src" "$mask_dst"
        mask_path="$mask_dst"
        echo "       -> Sessionless: copied existing mask to canonical ses-1 location: $(basename "$mask_dst")"
      else
        mask_path="$mask_dst"
      fi
    else
      mask_path="$mask_src"
    fi

    # ---- Step A: Create_Masks.py (skip if outputs exist) ----
    if [[ "$FORCE_RERUN" != "1" && -f "$mask_path" && ( -f "$rare_be_src1" || -f "$rare_be_src2" ) ]]; then
      echo "       -> Mask + RARE brain_extracted already exist: skip Create_Masks.py"
    else
      echo "       -> Create mask from RARE..."
      "$PYTHON_BIN" "$CREATE_MASK_SCRIPT" \
        --input "$rare" \
        --bids-root "$BIDS_DIR" \
        --out-root "$OUT_ROOT"
    fi

    # If Create_Masks produced only mask_src for sessionless, copy to canonical
    if [[ "$assume_ses1" == "1" && ! -f "$mask_path" && -f "$mask_src" ]]; then
      cp -f "$mask_src" "$mask_dst"
      mask_path="$mask_dst"
      echo "       -> Sessionless: copied generated mask to canonical ses-1 location: $(basename "$mask_dst")"
    fi

    if [[ ! -f "$mask_path" ]]; then
      echo "       [WARN] Mask not found after Create_Masks: $mask_path"
      echo "       [WARN] Skip optional modalities for this case."
      echo ""
      continue
    fi

    # Canonicalize RARE brain_extracted name for sessionless datasets (fast rename only if needed)
    rare_be_src="${brain_extracted_root}/RARE/${rare_base}_brain_extracted.nii.gz"
    if [[ "$assume_ses1" == "1" && -f "$rare_be_src" ]]; then
      rare_be_dst="${brain_extracted_root}/RARE/${rare_base_canon}_brain_extracted.nii.gz"
      if [[ "$rare_be_dst" != "$rare_be_src" && ! -f "$rare_be_dst" ]]; then
        mv -f "$rare_be_src" "$rare_be_dst"
        echo "       -> Sessionless: renamed RARE brain_extracted to canonical: $(basename "$rare_be_dst")"
      fi
    fi

    # ---- Apply mask to OPTIONAL modalities ----
    if [[ ${#requested_modalities[@]} -eq 0 ]]; then
      echo "       -> No optional modalities requested (--modalities empty)."
      echo ""
      continue
    fi

    for mod in "${requested_modalities[@]}"; do
      img="${SESSION_MOD_PATH[$mod]:-}"

      if [[ -z "$img" ]]; then
        echo "       ${mod}: <missing> (optional) -> skip"
        continue
      fi

      echo "       ${mod}: $img"

      img_base="$(basename_nii "$img")"
      if [[ "$assume_ses1" == "1" ]]; then
        img_base="$(canon_add_ses1_if_missing "$img_base")"
      fi

      mkdir -p "${brain_extracted_root}/${mod}"
      out_img="${brain_extracted_root}/${mod}/${img_base}_brain_extracted.nii.gz"

      if [[ -f "$out_img" && "$FORCE_RERUN" != "1" ]]; then
        echo "       -> ${mod} brain_extracted exists: $(basename "$out_img") (skip)"
      else
        echo "       -> Apply mask on ${mod}..."
        "$PYTHON_BIN" "$MASK_APPLY_SCRIPT" \
          --mask "$mask_path" \
          --acq "$img" \
          --output "$out_img"
      fi

      modality_found["$mod"]=1
    done

    echo ""
  done
done

echo_hr

# ============================================================
# STEP 4: Align RARE brain_extracted -> Allen (transforms + warped)
# ============================================================
echo "=== Align RARE brain_extracted to Allen (antsRegistrationSyN.sh) ==="
echo "â†’ Allen template: $ALLEN_TEMPLATE (ID=$ALLEN_ID)"
echo "â†’ Transform type: $RARE_TRANSFORM_TYPE (a=affine, s=SyN)"

if [[ "$FORCE_RERUN" != "1" ]] && rare_allen_outputs_ready; then
  echo "âœ… RAREâ†’Allen outputs already exist for all SELECTED cases: skip Rare_alignement.sh"
else
  BIDS_DIR="$OUT_ROOT" \
  DERIV_DIR="$OUT_ROOT/derivatives" \
  BRAIN_EXTRACTED_DIR="$OUT_ROOT/derivatives/Brain_extracted" \
  ALLEN_TEMPLATE="$ALLEN_TEMPLATE" \
  TRANSFORM_TYPE="$RARE_TRANSFORM_TYPE" \
  bash "$RARE_ALIGN_SCRIPT"
fi
echo_hr

# ============================================================
# STEP 5: Align OPTIONAL modalities -> Allen (apply RARE->Allen transforms)
# ============================================================
echo "=== Align optional modalities to Allen (using RAREâ†’Allen transforms) ==="
TRANSFORM_DIR="${brain_extracted_root}/RARE/matrice_transforms"
[[ -d "$TRANSFORM_DIR" ]] || { echo "ERROR: TRANSFORM_DIR not found: $TRANSFORM_DIR"; exit 1; }

align_mod_to_allen() {
  local modality="$1"
  local in_dir="${brain_extracted_root}/${modality}"
  local out_dir="${in_dir}/aligned"
  mkdir -p "$out_dir"

  local files=( "${in_dir}"/*_brain_extracted.nii.gz "${in_dir}"/*_brain_extracted.nii )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "â†’ [$modality] no brain_extracted inputs found in $in_dir (skip)"
    return 0
  fi

  echo "â†’ [$modality] input: $in_dir"
  for img in "${files[@]}"; do
    [[ -f "$img" ]] || continue
    local img_base
    img_base="$(basename_nii "$img")"

    local sub sesnum ses suffix case_id
    if [[ "$img_base" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)$ ]]; then
      sub="${BASH_REMATCH[1]}"
      sesnum="${BASH_REMATCH[2]}"
      ses="ses-${sesnum}"
      suffix="${BASH_REMATCH[3]}"
    else
      if [[ "$img_base" =~ ^(sub-[0-9]+)_(.+)$ ]]; then
        sub="${BASH_REMATCH[1]}"
        sesnum="1"
        ses="ses-1"
        suffix="${BASH_REMATCH[2]}"
        img_base="${sub}_${ses}_${suffix}"
      else
        echo "  ! [$modality] bad filename (skip): $(basename "$img")"
        continue
      fi
    fi

    case_id="${sub}_${ses}"
    if [[ ${#requested_modalities[@]} -gt 0 && "$FILTER_BY_MODALITIES" == "1" ]]; then
      [[ -n "${SELECTED_CASES[$case_id]+x}" ]] || { echo "  â© [$modality] not selected: $case_id (skip)"; continue; }
    fi

    local rare_base="${sub}_${ses}_RARE_brain_extracted"
    local affine="${TRANSFORM_DIR}/${rare_base}_aligned_to_${ALLEN_ID}_0GenericAffine.mat"
    local warp="${TRANSFORM_DIR}/${rare_base}_aligned_to_${ALLEN_ID}_1Warp.nii.gz"

    if [[ ! -f "$affine" && ! -f "$warp" ]]; then
      echo "  ! [$modality] no transforms for $sub $ses (skip)"
      continue
    fi

    local out_file="${out_dir}/${img_base}_aligned_to_${ALLEN_ID}.nii.gz"
    if [[ -f "$out_file" && "$FORCE_RERUN" != "1" ]]; then
      echo "  â© [$modality] exists: $(basename "$out_file") (skip)"
      continue
    fi

    echo "  â†’ [$modality] $img_base â†’ Allen"

    if [[ -f "$warp" ]]; then
      antsApplyTransforms -d 3 \
        -i "$img" \
        -r "$ALLEN_TEMPLATE" \
        -o "$out_file" \
        -t "$warp" \
        -t "$affine" \
        --interpolation "BSpline[3]" \
        --float 1
    else
      antsApplyTransforms -d 3 \
        -i "$img" \
        -r "$ALLEN_TEMPLATE" \
        -o "$out_file" \
        -t "$affine" \
        --interpolation "BSpline[3]" \
        --float 1
    fi

    echo "    âœ“ $out_file"
  done
}

# loop only through modalities actually found/processed
mods_to_align=()
for m in "${requested_modalities[@]}"; do
  if [[ -n "${modality_found[$m]+x}" ]]; then
    mods_to_align+=( "$m" )
  fi
done

if [[ ${#mods_to_align[@]} -eq 0 ]]; then
  echo "â†’ No optional modalities were found/processed => nothing to align (RARE already aligned)."
else
  for m in "${mods_to_align[@]}"; do
    align_mod_to_allen "$m"
  done
fi

echo "=== Done: Allen-space alignment ==="
echo_hr

# Stop here ONLY if requested explicitly
if [[ "$STOP_AFTER_ALLEN" == "1" ]]; then
  echo "âœ… Stopping after Allen alignment (--stop-after-allen)."
  exit 0
fi

# ============================================================
# Groups used later (templates / ROI)
# ============================================================
brain_extracted_root="${OUT_ROOT}/derivatives/Brain_extracted"
GROUPS_NEEDED="$(detect_groups_from_rare_inputs)"
echo "â†’ Groups detected (from SELECTED cases): ${GROUPS_NEEDED}"
echo_hr

# ============================================================
# SINGLE-SUBJECT MODE: prepare Allen-space averages for ROI extraction
# ============================================================
if [[ "$DO_TEMPLATE_STEPS" == "0" ]]; then
  echo "=== Single-subject mode: skip template steps, prepare Allen-space avgs for ROI extraction ==="
  if [[ ${#mods_to_align[@]} -eq 0 ]]; then
    echo "â†’ No optional modality aligned to Allen => ROI extraction will be skipped later."
  else
    for m in "${mods_to_align[@]}"; do
      build_allen_space_avgs_for_roi "$m"
    done
  fi
  echo_hr
fi

# ============================================================
# STEP 6 + 7: Template steps (only if enabled)
# ============================================================
if [[ "$DO_TEMPLATE_STEPS" == "1" ]]; then

  echo "=== Build RARE template(s) ==="
  echo "â†’ Groups to process: ${GROUPS_NEEDED}"

  for g in ${GROUPS_NEEDED}; do
    final_tpl="${brain_extracted_root}/RARE/${g}/template/0.1/template/{$g}_RARE_template0.nii.gz"
    if [[ -f "$final_tpl" && "$FORCE_RERUN" != "1" ]]; then
      echo "â© RARE template exists for ${g}: $final_tpl (skip)"
      continue
    fi

    echo "---- RARE template group: $g ----"
    run_optional env \
      BIDS_DIR="$OUT_ROOT" \
      DERIV_DIR="$OUT_ROOT/derivatives" \
      BRAIN_EXTRACTED_DIR="$OUT_ROOT/derivatives/Brain_extracted" \
      INPUT_MODE="auto" \
      USE_ALLEN_REF="$USE_ALLEN_REF" \
      ALLEN_REF_TEMPLATE="$ALLEN_TEMPLATE" \
      bash "$RARE_TEMPLATE_SCRIPT" "RARE" "$g" \
    || echo "  [WARN] RARE template step failed for group $g (continuing)."
  done
  echo_hr

  # STEP 7: Apply template transforms to modalities + compute avgs (caching-aware)
  if [[ ${#mods_to_align[@]} -eq 0 ]]; then
    echo "=== No optional modalities processed => skipping Apply_to_Template + modality avgs ==="
    echo_hr
  else
    for m in "${mods_to_align[@]}"; do
      echo "=== Modality to template: $m ==="

      if [[ "$FORCE_RERUN" != "1" ]]; then
        all_exist=1
        for g in ${GROUPS_NEEDED}; do
          avg="${brain_extracted_root}/${m}/To_Template/${g}/template/${g}_${m}_avg.nii.gz"
          [[ -f "$avg" ]] || { all_exist=0; break; }
        done
        if [[ "$all_exist" == "1" ]]; then
          echo "â© All avg templates exist for $m (all groups): skip Apply_to_Template + AverageImages"
          echo_hr
          continue
        fi
      fi

      if [[ -f "$APPLY_TO_TEMPLATE_SCRIPT" ]]; then
        echo "â†’ Apply RARE-template transforms to $m"
        run_optional env \
          BIDS_DIR="$OUT_ROOT" \
          DERIV_DIR="$OUT_ROOT/derivatives" \
          BRAIN_EXTRACTED_DIR="$OUT_ROOT/derivatives/Brain_extracted" \
          INPUT_MODE="allen" \
          INTERP="BSpline[3]" \
          bash "$APPLY_TO_TEMPLATE_SCRIPT" "$m" \
        || echo "[WARN] Apply_to_Template failed for $m (continuing)."
      else
        echo "[WARN] Apply_to_Template.sh not found: $APPLY_TO_TEMPLATE_SCRIPT (skip)"
      fi

      echo "â†’ Compute modality template averages"
      compute_modality_template_avgs "$m" ${GROUPS_NEEDED}

      echo_hr
    done
  fi

else
  echo "=== Template steps skipped (single-subject mode) ==="
  echo_hr
fi

# ============================================================
# STEP 8: ROI extraction (Graph_1ROI.py)
# ============================================================
if [[ "$SKIP_ROI" == "1" ]]; then
  echo "=== ROI extraction skipped (--skip-roi) ==="
  echo "âœ… Done."
  exit 0
fi

if [[ ${#mods_to_align[@]} -eq 0 ]]; then
  echo "=== ROI extraction skipped (no optional modalities available) ==="
  echo "âœ… Done."
  exit 0
fi

if [[ ! -f "$ROI_SCRIPT" ]]; then
  echo "=== ROI extraction skipped (Graph_1ROI.py not found) ==="
  echo "âœ… Done."
  exit 0
fi

if [[ "$FORCE_RERUN" != "1" ]]; then
  # groups needed already computed from SELECTED cases
  if roi_tables_exist_for_all "${mods_to_align[@]}"; then
    echo "â© ROI tables already exist for all GroupÃ—Modality: skip Graph_1ROI.py"
    echo "âœ… Done."
    exit 0
  fi
fi

echo "=== Extract ROI stats (ALL labels, TSV per GroupÃ—Modality, PNG per ROI) ==="
roi_modalities="$(IFS=','; echo "${mods_to_align[*]}")"

run_optional "$PYTHON_BIN" "$ROI_SCRIPT" \
  --out-root "$OUT_ROOT" \
  --labels "$ALLEN_LABELS" \
  --labels-table "$ALLEN_LABELS_TABLE" \
  --modalities "$roi_modalities" \
  --per-roi-png \
  --roi-ids all \
|| echo "[WARN] ROI extraction failed (continuing)."

echo "âœ… Done."
