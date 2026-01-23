#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import argparse
import ants

# NOTE (dataset-specific): will be removed later (kept intentionally for now)
EXCLUSION_LIST = [
    "sub-07_ses-3",
]


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Apply a binary/soft brain mask to an acquisition image using ANTsPy. "
            "This script multiplies the acquisition by the mask voxel-wise."
        )
    )
    parser.add_argument(
        "--mask",
        required=True,
        help="Full path to the mask image (e.g., sub-01_ses-1_RARE_mask_final.nii.gz).",
    )
    parser.add_argument(
        "--acq",
        required=True,
        help="Full path to the acquisition image to be masked.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Full path where the masked image will be saved.",
    )

    args = parser.parse_args()

    acq_filename = os.path.basename(args.acq)

    # Dataset-specific exclusion (kept intentionally for now)
    if any(exclusion in acq_filename for exclusion in EXCLUSION_LIST):
        print(f"[SKIP] Excluded subject detected in filename: {acq_filename}. No processing performed.")
        return

    # Skip if output already exists
    if os.path.exists(args.output):
        print(f"[SKIP] Output already exists: {args.output}. No processing performed.")
        return

    # Basic input checks (publication-friendly failure mode)
    if not os.path.isfile(args.mask):
        raise SystemExit(f"[ERROR] Mask file not found: {args.mask}")
    if not os.path.isfile(args.acq):
        raise SystemExit(f"[ERROR] Acquisition file not found: {args.acq}")

    # Read images
    mask_img = ants.image_read(args.mask)
    acq_img = ants.image_read(args.acq)

    # Apply mask (voxel-wise multiplication)
    masked_img = acq_img * mask_img

    # Ensure output directory exists
    output_dir = os.path.dirname(args.output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    # Write output
    ants.image_write(masked_img, args.output)
    print(f"[OK] Mask applied successfully: {args.output}")


if __name__ == "__main__":
    main()
