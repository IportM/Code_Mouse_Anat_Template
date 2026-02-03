#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Brain Extraction Pipeline for RARE images.

This script performs the following steps to extract the brain:
1. N4 Bias Field Correction (2 passes)
2. Probabilistic brain extraction using ANTsPyNet
3. Adaptive thresholding (Otsu)
4. Morphological operations (Erosion, Largest Component, Dilation, Fill Holes)
5. Final masking
"""

import logging
import os
import argparse
import ants
import antspynet

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def _strip_nii_ext(filename: str) -> str:
    """
    Remove .nii or .nii.gz extension from a filename.

    Parameters
    ----------
    filename : str
        The filename to strip.

    Returns
    -------
    str
        The base filename without extension.
    """
    if filename.endswith(".nii.gz"):
        return filename[:-7]
    if filename.endswith(".nii"):
        return filename[:-4]
    return os.path.splitext(filename)[0]


def process_file(input_path: str, derived_output_path: str, brain_out_dir: str,
                 erosion_radius: int = 6, save_steps: bool = False) -> str:
    """
    Execute the brain extraction pipeline on a single image.

    Pipeline steps:
    - N4 bias correction (2 consecutive passes)
    - Probabilistic brain extraction (antspynet)
    - Adaptive thresholding (Otsu)
    - Morphology: erosion + largest component + dilation + FillHoles

    Parameters
    ----------
    input_path : str
        Path to the input raw image (NIfTI).
    derived_output_path : str
        Path where the final brain-extracted image should be saved (local/derivatives folder).
    brain_out_dir : str
        Directory where a copy of the brain-extracted image is stored (central repository).
    erosion_radius : int, optional
        Radius for morphological erosion and dilation. Default is 6.
    save_steps : bool, optional
        If True, intermediate images (QC steps) are saved to a 'step' subdirectory.

    Returns
    -------
    str
        The full path to the final binary mask created.
    """
    base_name = _strip_nii_ext(os.path.basename(input_path))

    logging.info(f"Reading image: {input_path}")
    image = ants.image_read(input_path)

    output_dir = os.path.dirname(derived_output_path)
    step_dir = os.path.join(output_dir, "step")
    step_counter = 1
    
    if save_steps:
        os.makedirs(step_dir, exist_ok=True)
        ants.image_write(image, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_input.nii.gz"))
        step_counter += 1

    # 1) N4 bias correction (pass 1)
    logging.info("N4 bias field correction (pass 1)...")
    image = ants.n4_bias_field_correction(image, shrink_factor=4, convergence={"iters": [20, 20, 10], "tol": 1e-6})
    if save_steps:
        ants.image_write(image, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_n4_pass1.nii.gz"))
        step_counter += 1

    # 2) N4 bias correction (pass 2)
    logging.info("N4 bias field correction (pass 2)...")
    image = ants.n4_bias_field_correction(image, shrink_factor=2, convergence={"iters": [30, 20, 10], "tol": 1e-6})
    if save_steps:
        ants.image_write(image, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_n4_pass2.nii.gz"))
        step_counter += 1

    # 3) Brain extraction (probability map)
    logging.info("Brain extraction (antspynet)...")
    proba_image = antspynet.mouse_brain_extraction(image)
    if save_steps:
        ants.image_write(proba_image, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_proba.nii.gz"))
        step_counter += 1

    # 4) Adaptive thresholding (Otsu)
    logging.info("Adaptive thresholding (Otsu)...")
    mask = ants.threshold_image(proba_image, "Otsu", 1, 0)
    if save_steps:
        ants.image_write(mask, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_otsu.nii.gz"))
        step_counter += 1

    # 5) Morphology: erosion
    logging.info(f"Morphology: erosion (radius={erosion_radius})...")
    mask_eroded = ants.iMath(mask, "ME", erosion_radius)
    if save_steps:
        ants.image_write(mask_eroded, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_eroded.nii.gz"))
        step_counter += 1

    # 6) Keep largest component
    logging.info("Keeping largest connected component...")
    mask_component = ants.iMath(mask_eroded, "GetLargestComponent", 10000)
    if save_steps:
        ants.image_write(mask_component, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_largest_component.nii.gz"))
        step_counter += 1

    # 7) Morphology: dilation
    logging.info(f"Morphology: dilation (radius={erosion_radius})...")
    mask_dilated = ants.iMath(mask_component, "MD", erosion_radius)
    if save_steps:
        ants.image_write(mask_dilated, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_dilated.nii.gz"))
        step_counter += 1

    # 8) Fill holes
    logging.info("Filling holes...")
    mask_filled = ants.iMath(mask_dilated, "FillHoles", 0.3)
    if save_steps:
        ants.image_write(mask_filled, os.path.join(step_dir, f"{base_name}_step{step_counter:02d}_fillholes.nii.gz"))
        step_counter += 1

    # 9) Apply final mask
    logging.info("Applying final mask...")
    brain_image = ants.multiply_images(image, mask_filled)

    os.makedirs(brain_out_dir, exist_ok=True)
    brain_out_path = os.path.join(brain_out_dir, f"{base_name}_brain_extracted.nii.gz")
    ants.image_write(brain_image, brain_out_path)

    final_mask_path = os.path.join(output_dir, f"{base_name}_mask_final.nii.gz")
    ants.image_write(mask_filled, final_mask_path)

    logging.info(f"Brain extracted: {brain_out_path}")
    logging.info(f"Final mask saved: {final_mask_path}")

    return final_mask_path


def _is_rare_file(filename: str) -> bool:
    """
    Check if a filename corresponds to a RARE acquisition.

    Parameters
    ----------
    filename : str
        The filename to check.

    Returns
    -------
    bool
        True if the file ends with _RARE.nii or _RARE.nii.gz, False otherwise.
    """
    return filename.endswith("_RARE.nii.gz") or filename.endswith("_RARE.nii")


def main():
    """
    Main entry point for brain extraction.
    Supports recursive scanning of a BIDS root directory or processing a single file.
    """
    parser = argparse.ArgumentParser(description="Brain extraction for RARE.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("-r", "--root", help="Scan recursively (original behavior)")
    group.add_argument("--input", help="Process a single RARE file")

    parser.add_argument("--bids-root", help="BIDS root (required with --input)")
    parser.add_argument("--out-root", help="Output root (required with --input)")
    parser.add_argument("--save-steps", action="store_true", help="Write step-by-step QC outputs.")
    
    args = parser.parse_args()

    # Default morphology parameter (Hardcoded logic removed)
    DEFAULT_EROSION = 6

    # --- Scan mode ---
    if args.root:
        root_dir = os.path.abspath(args.root)
        derivatives_dir = os.path.join(root_dir, "derivatives")
        brain_root = os.path.join(derivatives_dir, "Brain_extracted", "RARE")
        os.makedirs(brain_root, exist_ok=True)

        for dirpath, dirnames, filenames in os.walk(root_dir):
            dirnames[:] = [d for d in dirnames if d != "derivatives"]

            for filename in filenames:
                if not _is_rare_file(filename):
                    continue

                input_file = os.path.join(dirpath, filename)
                rel_path = os.path.relpath(dirpath, root_dir)
                output_dir = os.path.join(derivatives_dir, rel_path)
                os.makedirs(output_dir, exist_ok=True)

                base_name = _strip_nii_ext(filename)
                mask_final_path = os.path.join(output_dir, f"{base_name}_mask_final.nii.gz")
                
                if os.path.exists(mask_final_path):
                    continue

                derived_output_path = os.path.join(output_dir, f"{base_name}_brain_extracted.nii.gz")
                logging.info(f"Processing: {input_file}")

                try:
                    process_file(input_file, derived_output_path, brain_root, erosion_radius=DEFAULT_EROSION, save_steps=args.save_steps)
                except Exception as e:
                    logging.error(f"Failed processing {input_file}: {e}")
        return

    # --- Single-file mode ---
    if not args.bids_root or not args.out_root:
        raise SystemExit("ERROR: --bids-root and --out-root are required with --input")

    bids_root = os.path.abspath(args.bids_root)
    out_root = os.path.abspath(args.out_root)
    input_file = os.path.abspath(args.input)

    if not os.path.isfile(input_file):
        raise SystemExit(f"ERROR: input file not found: {input_file}")

    derivatives_dir = os.path.join(out_root, "derivatives")
    brain_root = os.path.join(derivatives_dir, "Brain_extracted", "RARE")
    os.makedirs(brain_root, exist_ok=True)

    dirpath = os.path.dirname(input_file)
    # Handle cases where input might be outside BIDS root (robustness)
    try:
        rel_path = os.path.relpath(dirpath, bids_root)
    except ValueError:
        rel_path = os.path.basename(dirpath)

    output_dir = os.path.join(derivatives_dir, rel_path)
    os.makedirs(output_dir, exist_ok=True)

    filename = os.path.basename(input_file)
    base_name = _strip_nii_ext(filename)
    
    mask_final_path = os.path.join(output_dir, f"{base_name}_mask_final.nii.gz")
    if os.path.exists(mask_final_path):
        logging.info(f"[SKIP] Mask already exists for {base_name}, skipping.")
        return

    derived_output_path = os.path.join(output_dir, f"{base_name}_brain_extracted.nii.gz")
    logging.info(f"Processing: {input_file}")
    
    process_file(input_file, derived_output_path, brain_root, erosion_radius=DEFAULT_EROSION, save_steps=args.save_steps)


if __name__ == "__main__":
    main()