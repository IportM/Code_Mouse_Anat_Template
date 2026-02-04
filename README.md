# FC3R Mouse Anat Pipeline

[![Python version badge](https://img.shields.io/badge/python-3.12.0-blue)](https://www.python.org/)
[![Bash badge](https://img.shields.io/badge/shell-bash-black)](https://www.gnu.org/software/bash/)

**FC3R Mouse Anat Pipeline** is the main library supporting anatomical MRI processing for the FC3R project.

This pipeline automates the processing of mouse brain MRI data formatted in [BIDS](https://bids.neuroimaging.io/). It handles brain extraction, registration to the Allen Atlas, group template creation, and ROI-based statistical extraction. The architecture combines Bash scripting for workflow management and Python for image processing.

## Features

The pipeline uses the **RARE** sequence as the geometric reference and performs the following steps:

1.  **Brain Extraction**: Hybrid approach using N4 bias correction, Deep Learning (`antspynet`), and adaptive thresholding.
2.  **Registration**: Non-linear registration (SyN) of RARE images to the Allen Atlas (100µm).
3.  **Template Construction**: Automatic generation of a study-specific group template.
4.  **Multi-modal Mapping**: Application of transforms to other modalities (e.g., T1map, UNIT1).
5.  **ROI Analysis**: Automated extraction of statistics (mean, std, median) for each Allen Atlas region.

##  System Requirements

Before running the pipeline, ensure the following dependencies are installed on your system:

* **ANTs (Advanced Normalization Tools)**: The pipeline relies on `antsRegistrationSyN`, `antsApplyTransforms`, etc.
    * [Installation Guide](https://github.com/ANTsX/ANTs)
* **Git**: To clone the repository.
* **Python 3.8.10**: For the processing scripts.

##  Installation

We highly recommend installing the Python dependencies in a **Virtual Environment**.

#### 1. Clone the repository

```bash
git clone https://github.com/IportM/Code_Mouse_Anat_Template.git
cd Code_Mouse_Anat_Template
```

#### 2. Set up the environment
```bash
# Create a virtual environment (optional)
python3 -m venv venv

# Activate it
source venv/bin/activate

# Upgrade pip
pip install --upgrade pip
```

#### 3. Install Python dependencies
Install the required scientific libraries (AntsPyNet, Nibabel, Pandas, etc.):
```bash
pip install antspynet nibabel pandas numpy argparse matplotlib scipy
```
or you can install via the requirements.txt
```bash
pip install -r requirements.txt
```
#### 4. Permissions
Ensure the scripts are executable (especially after cloning):
```bash
chmod +x run_anat_pipeline.sh
chmod +x scripts/*.sh
chmod +x scripts/*.py
```
# Usage

The pipeline is driven by the master script run_anat_pipeline.sh.

## Example

### To process a full BIDS dataset:

#### 1. Activate environment
```bash
source venv/bin/activate
```
#### 2. Run pipeline
```bash
./run_anat_pipeline.sh /path/to/BIDS_ROOT \
    --out /path/to/output_folder \
    --group-name "study_group" \
    --modalities "T1map,UNIT1"
```
### To process a single subject

```bash
./run_anat_pipeline.sh /path/to/BIDS_ROOT/sub-01 \
    --out /path/to/output_folder \
    --force-template-single
```
### Command Line Options

| Option | Default | Description |
| :--- | :--- | :--- |
| **Input Arguments** | | |
| `INPUT_PATH` | *Required* | First argument. Path to the BIDS root directory or a specific subject folder (`sub-XX`). |
| `--out` | `$PWD/BIDS_driver_output` | Directory where the `derivatives/` folder will be created. |
| `--modalities` | `"T1map,UNIT1"` | Comma-separated list of additional modalities to process alongside RARE. |
| `--sessions` | *All* | Filter to process only specific sessions (e.g., `ses-1,ses-2`). |
| **Workflow Control** | | |
| `--group-name` | `"study"` | Name of the output folder for the group template (e.g., "WT", "KO"). |
| `--stop-after-allen` | `Off` | Stops the pipeline immediately after individual registration. Skips template creation and ROI stats. |
| `--force-template-single`| `Off` | **Crucial for single subject:** Forces the "template" creation step even if only 1 subject is present (allows ROI stats to run). |
| `--skip-roi` | `Off` | Skips the statistical extraction step (CSV/PNG generation). |
| `--force` | `Off` | Forces re-calculation of existing files (overwrites outputs). |
| **Advanced Processing** | | |
| `--rare-transform` | `"a"` | Type of registration to Allen Atlas: `a` (Rigid+Affine) or `s` (SyN/Deformable). |
| `--no-allen-ref` | `Off` | If set, disables using the Allen Atlas as an initialization reference during template construction. |
| `--keep-all-rare` | `Off` | Process **all** subjects with a RARE image, even if they miss the requested optional modalities. |
| `--require-all-modalities`| `Off` | Strict mode: Skips any subject that does not have **all** the requested modalities. |

## Output Structure

The pipeline generates a BIDS-compliant derivatives folder:
```bash
output_folder/
└── derivatives/
    ├── Brain_extracted/
    │   ├── RARE/
    │   │   ├── transforms/       # .mat and .nii.gz warps to Allen
    │   │   ├── aligned/          # RARE images resampled to Allen space
    │   │   └── sub-01_brain_extracted.nii.gz
    │   └── T1map/                # Other modalities (aligned)
    │       ├── aligned/
    │       ├── To_template/study-name/
    │       │   └── template/
    │       └── sub-01_T1map_brain_extracted.nii.gz
    │
    ├── templates/
    │   └── study-name/
    │       └── RARE/
    │           └── res-0.1mm/    # Final Group Template
    │
    ├── ROI_stats/
    │   ├── plots_by_roi/
    │   │   └── study-name/
    │   │       └── T1map/
    │   │           └── study-name_T1map_ROI.png
    │   └── study_name/
    │       └── study-name_T1map_roi_stats.tsv
    │
    └── sub-01/(ses-1)/
        └── anat/
            └── sub-01_(ses-1)_RARE_mask_final.nii.gz
```

###  Statistical Metrics Output
Description of the columns generated in the output statistics files (`*_roi_stats.tsv` or `*.csv`).

| Metric | Type | Description |
| :--- | :--- | :--- |
| **Volume & Central Tendency** | | |
| `n_voxels` | Count | Total number of voxels included in the Region of Interest (ROI). |
| `mean` | Float | Arithmetic mean of signal intensity within the ROI. |
| `median` | Float | Median value (50th percentile) of the distribution. |
| **Dispersion & Extremes** | | |
| `std` | Float | Standard deviation, measuring the spread of values around the mean. |
| `iqr` | Float | Interquartile Range ($Q3 - Q1$), a robust measure of statistical dispersion. |
| `min` | Float | Minimum intensity value observed in the ROI. |
| `max` | Float | Maximum intensity value observed in the ROI. |
| **Distribution Shape** | | |
| `q1` / `q3` | Float | First (25%) and Third (75%) quartiles. |
| `p05` / `p95` | Float | 5th and 95th percentiles (useful to exclude extreme outliers/noise). |
| `pct_within_1sd` | Percent | Percentage of voxels falling within the [Mean $\pm$ 1 SD] range.  |
| `pct_within_whiskers` | Percent | Percentage of voxels within Tukey's whiskers ($[Q1 - 1.5 \times IQR, Q3 + 1.5 \times IQR]$). |