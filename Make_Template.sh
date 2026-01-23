#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

usage() {
  cat <<EOF
Usage: $(basename "$0") <modality> [--force]

Build per-group average images in template space using AverageImages.

Inputs expected:
  derivatives/Brain_extracted/<MODALITY>/To_Template/<GROUP>/*_in_template.nii[.gz]

Outputs written:
  derivatives/Brain_extracted/<MODALITY>/To_Template/<GROUP>/template/<GROUP>_<MODALITY>_template.nii.gz

Options:
  --force   Recompute even if output exists (or set FORCE_RERUN=1).
EOF
  exit 1
}

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_skip() { echo "[SKIP] $*"; }
log_err()  { echo "[ERROR] $*" >&2; }

[[ $# -ge 1 ]] || usage
MODALITY="$1"; shift

FORCE_RERUN="${FORCE_RERUN:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_RERUN=1; shift ;;
    -h|--help) usage ;;
    *) log_err "Unknown arg: $1"; usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

INPUT_DIR="$BRAIN_EXTRACTED_DIR/${MODALITY}/To_Template"

log_info "Make modality average (AverageImages)"
log_info "MODALITY   : $MODALITY"
log_info "INPUT_DIR  : $INPUT_DIR"
log_info "FORCE_RERUN: $FORCE_RERUN"

if [[ ! -d "$INPUT_DIR" ]]; then
  log_warn "Input directory not found: $INPUT_DIR"
  exit 0
fi

for group_dir in "$INPUT_DIR"/S*/; do
  [[ -d "$group_dir" ]] || continue
  group="$(basename "$group_dir")"

  output_dir="${group_dir}/template"
  mkdir -p "$output_dir"
  output_file="${output_dir}/${group}_${MODALITY}_template.nii.gz"

  if [[ -f "$output_file" && "$FORCE_RERUN" != "1" ]]; then
    log_skip "Exists: $output_file"
    continue
  fi

  # Only average the per-subject/per-session files produced by Apply_to_Template
  map_files=( "$group_dir"/*_in_template.nii.gz "$group_dir"/*_in_template.nii )

  if [[ ${#map_files[@]} -eq 0 ]]; then
    log_warn "No *_in_template files for $group in $group_dir"
    continue
  fi

  log_info "Averaging ${#map_files[@]} file(s) for $group ($MODALITY) -> $output_file"
  AverageImages 3 "$output_file" 0 "${map_files[@]}"
  log_ok "Generated: $output_file"
done

log_ok "Done."
