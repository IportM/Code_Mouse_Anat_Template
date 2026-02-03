#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <modality>"
  exit 1
fi
MODALITY="$1"

BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$PWD}"
INPUT_DIR="$BRAIN_EXTRACTED_DIR/${MODALITY}/To_Template"
FORCE_RERUN="${FORCE_RERUN:-0}"

if [[ ! -d "$INPUT_DIR" ]]; then
  log_warn "Input directory not found: $INPUT_DIR"
  exit 0
fi

# Iterate over ANY subdirectory (agnostic: study, S01, etc.)
for group_dir in "$INPUT_DIR"/*/; do
  [[ -d "$group_dir" ]] || continue
  group="$(basename "$group_dir")"

  output_dir="${group_dir}/template"
  mkdir -p "$output_dir"
  output_file="${output_dir}/${group}_${MODALITY}_template.nii.gz"

  if [[ -f "$output_file" && "$FORCE_RERUN" != "1" ]]; then
    log_skip "Exists: $output_file"
    continue
  fi

  map_files=( "$group_dir"/*_in_template.nii.gz "$group_dir"/*_in_template.nii )

  if [[ ${#map_files[@]} -eq 0 ]]; then
    log_warn "No files to average in $group_dir"
    continue
  fi

  log_info "Averaging ${#map_files[@]} file(s) for $group -> $output_file"
  AverageImages 3 "$output_file" 0 "${map_files[@]}"
done