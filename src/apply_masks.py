#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import argparse
import ants

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Apply a binary/soft brain mask to an acquisition image."
    )
    parser.add_argument("--mask", required=True, help="Full path to the mask image.")
    parser.add_argument("--acq", required=True, help="Full path to the acquisition image.")
    parser.add_argument("--output", required=True, help="Full path where the masked image will be saved.")

    args = parser.parse_args()

    # Skip if output already exists (simple caching)
    if os.path.exists(args.output):
        print(f"[SKIP] Output already exists: {args.output}")
        return

    # Basic input checks
    if not os.path.isfile(args.mask):
        raise SystemExit(f"[ERROR] Mask file not found: {args.mask}")
    if not os.path.isfile(args.acq):
        raise SystemExit(f"[ERROR] Acquisition file not found: {args.acq}")

    try:
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
        print(f"[OK] Mask applied: {os.path.basename(args.output)}")
        
    except Exception as e:
        print(f"[ERROR] Failed to apply mask: {e}")
        exit(1)

if __name__ == "__main__":
    main()