#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import numpy as np
import pandas as pd
import nibabel as nib


def _quantiles(vals: np.ndarray, qs: List[float]) -> np.ndarray:
    """
    Robust quantiles helper compatible with older NumPy versions.
    Returns array of quantiles in the same order as qs.
    """
    vals = np.asarray(vals, dtype=np.float32)
    try:
        return np.quantile(vals, qs, method="linear")  # NumPy >= 1.22
    except TypeError:
        return np.quantile(vals, qs, interpolation="linear")  # older NumPy

def load_label_table(csv_path: Path) -> Dict[int, str]:
    df = pd.read_csv(csv_path)
    if "id" not in df.columns or "name" not in df.columns:
        raise ValueError(f"Label table must contain columns: id, name. Found: {list(df.columns)}")
    mapping: Dict[int, str] = {}
    for _, row in df.iterrows():
        try:
            i = int(row["id"])
        except Exception:
            continue
        name = str(row["name"]).strip()
        if name:
            mapping[i] = name
    return mapping


def label_name_from_id(
    roi_id: int,
    id_to_name: Dict[int, str],
    lr_offset: int,
    right_suffix: str,
    left_suffix: str,
) -> Tuple[int, str, str]:
    if roi_id == 0:
        return 0, "", "Background"

    if lr_offset > 0 and roi_id >= lr_offset:
        base_id = roi_id - lr_offset
        side = "L"
        base_name = id_to_name.get(base_id, f"ID_{base_id}")
        full = f"{base_name}{left_suffix}"
    else:
        base_id = roi_id
        side = "R"
        base_name = id_to_name.get(base_id, f"ID_{base_id}")
        full = f"{base_name}{right_suffix}"
    return base_id, side, full


def discover_templates(out_root: Path, modalities: List[str]) -> List[Tuple[str, str, Path]]:
    """
    OUT_ROOT/derivatives/Brain_extracted/<MOD>/To_Template/<GROUP>/template/*_template.nii.gz
    Returns (group, modality, template_path)
    """
    found: List[Tuple[str, str, Path]] = []
    for m in modalities:
        # On cherche uniquement dans To_Template (comme dans ta version originale)
        base = out_root / "derivatives" / "Brain_extracted" / m / "To_Template" 
        if not base.is_dir():
            continue
        for group_dir in sorted([p for p in base.glob("*") if p.is_dir()]):
            group = group_dir.name
            tpl_dir = group_dir / "template"
            if not tpl_dir.is_dir():
                continue

            expected = tpl_dir / f"{group}_{m}_template.nii.gz"
            if expected.exists():
                found.append((group, m, expected))
            else:
                hits = sorted(tpl_dir.glob("*_template.nii.gz"))
                if hits:
                    found.append((group, m, hits[0]))
    return found


def compute_stats_fast(
    label_data: np.ndarray,
    value_data: np.ndarray,
    include_negative: bool,
    compute_minmax: bool,
) -> Dict[int, Dict[str, float]]:
    labels = label_data.astype(np.int32).ravel()
    values = value_data.astype(np.float32).ravel()

    mask = np.isfinite(values)
    if not include_negative:
        mask &= (values >= 0)

    labels = labels[mask]
    values = values[mask]

    if labels.size == 0:
        return {}

    max_label = int(labels.max())

    counts = np.bincount(labels, minlength=max_label + 1).astype(np.int64)
    sums = np.bincount(labels, weights=values, minlength=max_label + 1).astype(np.float64)
    sums2 = np.bincount(labels, weights=(values * values), minlength=max_label + 1).astype(np.float64)

    with np.errstate(divide="ignore", invalid="ignore"):
        means = sums / counts
        vars_ = (sums2 / counts) - (means * means)
        vars_ = np.maximum(vars_, 0.0)
        stds = np.sqrt(vars_)

    # --- group by label (sorted) for robust stats + optional min/max ---
    order = np.argsort(labels, kind="mergesort")
    lab_s = labels[order]
    val_s = values[order]

    # boundaries per label
    starts = np.r_[0, np.where(np.diff(lab_s) != 0)[0] + 1]
    lab_unique = lab_s[starts]
    ends = np.r_[starts[1:], lab_s.size]

    # Optional min/max via reduceat (fast)
    min_map: Dict[int, float] = {}
    max_map: Dict[int, float] = {}
    if compute_minmax and lab_s.size > 0:
        mins = np.minimum.reduceat(val_s, starts)
        maxs = np.maximum.reduceat(val_s, starts)
        min_map = {int(l): float(v) for l, v in zip(lab_unique, mins)}
        max_map = {int(l): float(v) for l, v in zip(lab_unique, maxs)}

    # Robust stats maps
    q1_map: Dict[int, float] = {}
    med_map: Dict[int, float] = {}
    q3_map: Dict[int, float] = {}
    iqr_map: Dict[int, float] = {}
    p05_map: Dict[int, float] = {}
    p95_map: Dict[int, float] = {}
    pct1sd_map: Dict[int, float] = {}
    pctwhisk_map: Dict[int, float] = {}

    qs = [0.05, 0.25, 0.50, 0.75, 0.95]

    for rid, st, en in zip(lab_unique, starts, ends):
        rid = int(rid)
        vals_roi = val_s[st:en]
        n = vals_roi.size
        if n <= 0:
            continue

        q05, q25, q50, q75, q95 = _quantiles(vals_roi, qs)
        iqr = float(q75 - q25)

        p05_map[rid] = float(q05)
        q1_map[rid] = float(q25)
        med_map[rid] = float(q50)
        q3_map[rid] = float(q75)
        p95_map[rid] = float(q95)
        iqr_map[rid] = iqr

        # % within mean ± 1 std
        m = float(means[rid]) if rid < means.size else np.nan
        s = float(stds[rid]) if rid < stds.size else np.nan
        if np.isfinite(m) and np.isfinite(s):
            low1 = m - s
            high1 = m + s
            pct1 = 100.0 * float(np.mean((vals_roi >= low1) & (vals_roi <= high1)))
        else:
            pct1 = np.nan
        pct1sd_map[rid] = pct1

        # % within Tukey boxplot whiskers: [q1 - 1.5*IQR, q3 + 1.5*IQR]
        if np.isfinite(iqr):
            loww = float(q25 - 1.5 * iqr)
            highw = float(q75 + 1.5 * iqr)
            pctw = 100.0 * float(np.mean((vals_roi >= loww) & (vals_roi <= highw)))
        else:
            pctw = np.nan
        pctwhisk_map[rid] = pctw

    # Build per-label dict
    stats: Dict[int, Dict[str, float]] = {}
    for roi_id in np.unique(labels):
        rid = int(roi_id)
        n = int(counts[rid]) if rid < counts.size else 0
        if n <= 0:
            continue

        row: Dict[str, float] = {
            "n_voxels": n,
            "mean": float(means[rid]),
            "std": float(stds[rid]),
            "p05": float(p05_map.get(rid, np.nan)),
            "q1": float(q1_map.get(rid, np.nan)),
            "median": float(med_map.get(rid, np.nan)),
            "q3": float(q3_map.get(rid, np.nan)),
            "p95": float(p95_map.get(rid, np.nan)),
            "iqr": float(iqr_map.get(rid, np.nan)),
            "pct_within_1sd": float(pct1sd_map.get(rid, np.nan)),
            "pct_within_whiskers": float(pctwhisk_map.get(rid, np.nan)),
        }

        if compute_minmax:
            row["min"] = float(min_map.get(rid, np.nan))
            row["max"] = float(max_map.get(rid, np.nan))

        stats[rid] = row

    return stats


def parse_roi_ids(arg: str) -> Optional[List[int]]:
    """
    --roi-ids:
      - "" => None (auto)
      - "all" => all present
      - "214,2214,3" => list
    """
    s = (arg or "").strip().lower()
    if not s:
        return None
    if s == "all":
        return []
    out: List[int] = []
    for tok in s.split(","):
        tok = tok.strip()
        if not tok:
            continue
        out.append(int(tok))
    return out


def write_group_modality_table(df: pd.DataFrame, outdir: Path, group: str, modality: str, as_csv: bool) -> Path:
    outdir.mkdir(parents=True, exist_ok=True)
    ext = "csv" if as_csv else "tsv"
    sep = "," if as_csv else "\t"
    out_path = outdir / f"{group}_{modality}_roi_stats.{ext}"
    df.to_csv(out_path, sep=sep, index=False)
    return out_path

def plot_single_roi_distribution(
    values: np.ndarray,
    roi_id: int,
    roi_name: str,
    hemi: str,
    stats: Dict[str, float],
    out_png: Path,
    modality_label: str,
    max_points: int,
) -> None:
    """
    One PNG per ROI: boxplot + jittered sampled voxels + mean + ±1 SD + stats box + legend.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch

    vals = values.astype(np.float32)
    vals = vals[np.isfinite(vals)]
    if vals.size == 0:
        return

    # downsample points for display (but stats stay from full ROI)
    sampled = vals
    if max_points > 0 and vals.size > max_points:
        rng = np.random.default_rng(0)
        sampled = rng.choice(vals, size=max_points, replace=False)

    mean = float(stats.get("mean", np.nan))
    std = float(stats.get("std", np.nan))
    vmin = float(stats.get("min", np.nan))
    vmax = float(stats.get("max", np.nan))
    nvox = int(stats.get("n_voxels", vals.size))
    # p05 = float(stats.get("p05", np.nan)) # unused in plot
    # p95 = float(stats.get("p95", np.nan)) # unused in plot

    fig, ax = plt.subplots(figsize=(5.5, 7.5))

    # x-position for single ROI category
    x0 = 1.0

    # Boxplot (single)
    bp = ax.boxplot(
        [vals],
        positions=[x0],
        widths=0.35,
        patch_artist=True,
        showfliers=False,
        medianprops=dict(linewidth=1.2, color="black"),
        boxprops=dict(facecolor='lightcoral', color='black', alpha=0.6),
    )

    # Make box slightly transparent
    for box in bp["boxes"]:
        box.set_alpha(0.35)

    # Jittered points (sampled voxels)
    rng = np.random.default_rng(1)
    jitter = (rng.random(sampled.size) - 0.5) * 0.10  # +/- 0.05
    ax.scatter(
        np.full(sampled.size, x0) + jitter,
        sampled,
        s=10,
        alpha=0.25,
        color="black",
    )

    # Mean line
    if np.isfinite(mean):
        ax.axhline(mean, linestyle="--", linewidth=1.6, color="black")

    # ±1 SD lines
    if np.isfinite(mean) and np.isfinite(std):
        ax.axhline(mean + std, linestyle=":", linewidth=1.6, color="black")
        ax.axhline(mean - std, linestyle=":", linewidth=1.6, color="black")

    # Axes formatting
    ax.set_title(f"{roi_name} ({hemi}) (ID={roi_id})")
    ax.set_ylabel(f"{modality_label} value")
    ax.set_xticks([x0])
    ax.set_xticklabels([str(roi_id)], rotation=25)
    ax.grid(True, linestyle="--", alpha=0.35)

    # Stats box (top-right)
    txt = (
        f"n_voxels: {nvox}\n"
        f"mean: {mean:.6g}\n"
        f"std:  {std:.6g}\n"
        f"min:  {vmin:.6g}\n"
        f"max:  {vmax:.6g}\n"
    )

    ax.text(
        0.98, 0.98, txt,
        transform=ax.transAxes,
        ha="right", va="top",
        fontsize=10,
        bbox=dict(boxstyle="round", alpha=0.25),
    )

    # Legend
    legend_handles = [
        Patch(alpha=0.35, label="Boxplot", facecolor="lightcoral", edgecolor="black"),
        Line2D([0], [0], linestyle="--", linewidth=1.6, label="Mean", color="black"),
        Line2D([0], [0], linestyle=":", linewidth=1.6, label="±1 SD", color="black"),
        Line2D([0], [0], marker="o", linestyle="none", markersize=7, alpha=0.25, label="Sampled voxels", color="black"),
        Line2D([0], [0], marker="_", linewidth=1.6,  label="Median", color="black"),
    ]
    ax.legend(handles=legend_handles, loc="lower center", bbox_to_anchor=(0.5, -0.12), ncol=2)

    out_png.parent.mkdir(parents=True, exist_ok=True)
    plt.tight_layout()
    fig.savefig(out_png, dpi=160)
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Extract Allen ROI stats from FC3R templates. TSV per Group*Modality + PNG per ROI."
    )
    p.add_argument("--out-root", type=str, required=True, help="OUT_ROOT produced by your driver.")
    # MODIFICATION ICI : 'resources' au lieu de 'Ressources'
    p.add_argument("--labels", type=str, default="", help="Default: ./resources/100_AMBA_LR.nii.gz next to this script.")
    p.add_argument("--labels-table", type=str, default="", help="Default: ./resources/allen_labels_table.csv next to this script.")
    p.add_argument("--modalities", type=str, default="T1map,UNIT1", help="Comma-separated modalities.")
    p.add_argument("--outdir", type=str, default="", help="Default: OUT_ROOT/derivatives/ROI_stats")
    p.add_argument("--csv", action="store_true", help="Write CSV instead of TSV.")

    p.add_argument("--lr-offset", type=int, default=2000)
    p.add_argument("--right-suffix", type=str, default="_R")
    p.add_argument("--left-suffix", type=str, default="_L")

    p.add_argument("--include-negative", action="store_true")
    p.add_argument("--no-minmax", action="store_true")

    # Per-ROI plots
    p.add_argument("--per-roi-png", action="store_true",
                   help="Generate one PNG per ROI id (Group*Modality*ROI).")
    p.add_argument("--roi-ids", type=str, default="",
                   help="ROI ids to plot: 'all' or comma list like '214,2214'. Default: none.")
    p.add_argument("--roi-png-max", type=int, default=0,
                   help="Limit number of ROI PNGs per Group*Modality (0 = no limit).")
    p.add_argument("--roi-max-points", type=int, default=5000,
                   help="Max voxels to plot per ROI (random subsample). 0 = no subsample.")

    return p.parse_args()


def main() -> None:
    args = parse_args()

    out_root = Path(args.out_root).resolve()
    script_dir = Path(__file__).resolve().parent

    # MODIFICATION ICI : 'resources'
    labels_path = Path(args.labels).resolve() if args.labels else (script_dir / "resources/100_AMBA_LR.nii.gz")
    table_path = Path(args.labels_table).resolve() if args.labels_table else (script_dir / "resources/allen_labels_table.csv")

    if not labels_path.exists():
        raise FileNotFoundError(f"Labels NIfTI not found: {labels_path}")

    id_to_name: Dict[int, str] = {}
    if table_path.exists():
        id_to_name = load_label_table(table_path)

    modalities = [m.strip() for m in args.modalities.split(",") if m.strip()]
    template_list = discover_templates(out_root, modalities)
    if not template_list:
        # Comme on ne cherche que dans To_Template, si on n'a que RARE, c'est normal de ne rien trouver ici
        print(f"[INFO] No templates found in To_Template for modalities: {modalities}. (Skipping stats if none found).")
        return

    outdir = Path(args.outdir).resolve() if args.outdir else (out_root / "derivatives" / "ROI_stats")
    per_roi_png_dir = outdir / "plots_by_roi"  # plots_by_roi/<GROUP>/<MODALITY>/S01_T1map_214.png

    # Load labels
    lab_img = nib.load(str(labels_path))
    lab_data = np.asanyarray(lab_img.get_fdata()).astype(np.int32)
    roi_ids_present = np.unique(lab_data)
    roi_ids_present = roi_ids_present[roi_ids_present != 0].astype(int).tolist()

    roi_ids_req = parse_roi_ids(args.roi_ids)  # None, [] (=all), or explicit list

    for group, modality, tpl_path in template_list:
        tpl_img = nib.load(str(tpl_path))
        if tpl_img.shape != lab_img.shape:
            # Simple warning instead of crash if mismatch? or strict? Keeping strict for consistency.
            raise ValueError(f"Shape mismatch labels {lab_img.shape} vs template {tpl_img.shape}: {tpl_path}")

        tpl_data = np.asanyarray(tpl_img.get_fdata(dtype=np.float32))

        stats_map = compute_stats_fast(
            label_data=lab_data,
            value_data=tpl_data,
            include_negative=args.include_negative,
            compute_minmax=not args.no_minmax,
        )

        rows: List[Dict[str, object]] = []
        for roi_id in roi_ids_present:
            base_id, hemi, roi_name = label_name_from_id(
                roi_id=roi_id,
                id_to_name=id_to_name,
                lr_offset=args.lr_offset,
                right_suffix=args.right_suffix,
                left_suffix=args.left_suffix,
            )
            s = stats_map.get(roi_id, {})
            rows.append({
                "Group": group,
                "Modality": modality,
                "TemplateFile": tpl_path.name,  # reduced
                "ROI_id": int(roi_id),
                "ROI_base_id": int(base_id),
                "Hemisphere": hemi,
                "ROI_name": roi_name,
                "n_voxels": int(s.get("n_voxels", 0)),
                "mean": float(s.get("mean", np.nan)) if s else np.nan,
                "std": float(s.get("std", np.nan)) if s else np.nan,
                "min": float(s.get("min", np.nan)) if (s and not args.no_minmax) else np.nan,
                "max": float(s.get("max", np.nan)) if (s and not args.no_minmax) else np.nan,
                "p05": float(s.get("p05", np.nan)) if s else np.nan,
                "q1": float(s.get("q1", np.nan)) if s else np.nan,
                "median": float(s.get("median", np.nan)) if s else np.nan,
                "q3": float(s.get("q3", np.nan)) if s else np.nan,
                "p95": float(s.get("p95", np.nan)) if s else np.nan,
                "iqr": float(s.get("iqr", np.nan)) if s else np.nan,
                "pct_within_1sd": float(s.get("pct_within_1sd", np.nan)) if s else np.nan,
                "pct_within_whiskers": float(s.get("pct_within_whiskers", np.nan)) if s else np.nan,
            })

        df = pd.DataFrame(rows)

        num_cols = df.select_dtypes(include=[np.number]).columns
        df[num_cols] = df[num_cols].round(2)
        
        # 1) TSV per group*modality
        group_dir = outdir / group
        out_table = write_group_modality_table(df, group_dir, group, modality, as_csv=args.csv)
        print(f"[OK] ROI table: {out_table}")

        # 2) Per-ROI PNGs (voxel scatter)
        if args.per_roi_png:
            if roi_ids_req is None:
                continue

            if roi_ids_req == []:
                roi_ids_to_plot = roi_ids_present[:]  # all
            else:
                roi_ids_to_plot = roi_ids_req

            if args.roi_png_max > 0:
                roi_ids_to_plot = roi_ids_to_plot[: args.roi_png_max]

            for roi_id in roi_ids_to_plot:
                if roi_id == 0:
                    continue

                mask = (lab_data == int(roi_id))
                vals = tpl_data[mask]

                if not args.include_negative:
                    vals = vals[np.isfinite(vals) & (vals >= 0)]
                else:
                    vals = vals[np.isfinite(vals)]

                if vals.size == 0:
                    continue

                base_id, hemi, roi_name = label_name_from_id(
                    roi_id=int(roi_id),
                    id_to_name=id_to_name,
                    lr_offset=args.lr_offset,
                    right_suffix=args.right_suffix,
                    left_suffix=args.left_suffix,
                )

                s = stats_map.get(int(roi_id), {"n_voxels": int(vals.size), "mean": float(np.mean(vals)), "std": float(np.std(vals))})

                out_png = per_roi_png_dir / group / modality / f"{group}_{modality}_{int(roi_id)}.png"
                plot_single_roi_distribution(
                    values=vals,
                    roi_id=int(roi_id),
                    roi_name=roi_name,
                    hemi=hemi,
                    stats=s,
                    out_png=out_png,
                    modality_label=modality,
                    max_points=args.roi_max_points,
                )

            print(f"[OK] Per-ROI PNGs in: {per_roi_png_dir / group / modality}")


if __name__ == "__main__":
    main()