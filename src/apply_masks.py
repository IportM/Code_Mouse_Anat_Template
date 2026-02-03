#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script to apply a binary or soft brain mask to an acquisition image.
This script performs a voxel-wise multiplication between the input image
and the mask.

Usage:
    python apply_masks.py --mask <mask> --acq <acquisition> --output <output>
"""

import logging
import os
import argparse
import ants

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def main() -> None:
    """
    Main function to parse arguments and apply the mask.

    Parameters
    ----------
    None
        (Arguments are parsed from the command line)

    Returns
    -------
    None
    """
    parser = argparse.ArgumentParser(
        description="Apply a binary/soft brain mask to an acquisition image."
    )
    parser.add_argument("--mask", required=True, help="Full path to the mask image.")
    parser.add_argument("--acq", required=True, help="Full path to the acquisition image.")
    parser.add_argument("--output", required=True, help="Full path where the masked image will be saved.")

    args = parser.parse_args()

    # Skip if output already exists (simple caching)
    if os.path.exists(args.output):
        logging.info(f"Output already exists: {args.output}. Skipping.")
        return

    # Basic input checks
    if not os.path.isfile(args.mask):
        logging.error(f"Mask file not found: {args.mask}")
        raise SystemExit(1)
    if not os.path.isfile(args.acq):
        logging.error(f"Acquisition file not found: {args.acq}")
        raise SystemExit(1)

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
        logging.info(f"Mask applied successfully: {os.path.basename(args.output)}")
        
    except Exception as e:
        logging.error(f"Failed to apply mask: {e}")
        exit(1)

if __name__ == "__main__":
    main()