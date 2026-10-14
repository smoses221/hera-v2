"""Compare evaluated runs: summary table + bar chart (the before/after tool).

Runs are grouped by (code version, mode, tag); each group gets one bar per
scenario, the mean over its seeds, with the min..max range as error bar.
A group is an experiment (sim/experiments.py) and mode, plus the tag.
summary.md uses every seed of each group (listed in its table). The chart
compares groups on the same seeds only: per scenario, the seeds every group
has, so a group with more seeds doesn't look different just for that.
The UWB-only reference of each scenario is drawn alongside.

Usage: python3 sim/compare.py [--out DIR] <run_dir> [<run_dir> ...]
       python3 sim/compare.py data/sim/001_*/*_s* data/sim/004_*/*_s*   # 001 vs 004
sim/run.py calls it on its own runs (<experiment>/summary/). Comparisons
across experiments go by default to data/sim/comparisons/<date_time>/.
Writes runs.csv (one line per run), summary.md and rmse.png into --out.
"""

import argparse
import csv
import json
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np
import matplotlib

import experiments

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

COLUMNS = [
    ("experiment", lambda m: m["experiment"] or ""),
    ("scenario", lambda m: m["scenario"]),
    ("seed", lambda m: m["seed"]),
    ("mode", lambda m: m["mode"]),
    ("tag", lambda m: m.get("tag") or ""),
    ("commit", lambda m: m["git"].get("describe", "")),
    ("rmse_cm", lambda m: 100 * m["pos2d"]["rmse"]),
    ("settled_rmse_cm", lambda m: 100 * m["pos2d_settled"]["rmse"]),
    ("settled_p95_cm", lambda m: 100 * m["pos2d_settled"]["p95"]),
    ("max_cm", lambda m: 100 * m["pos2d"]["max"]),
    ("final_cm", lambda m: 100 * m["pos2d"]["final"]),
    ("z_rmse_cm", lambda m: 100 * m["z"]["rmse"]),
    ("vel_rmse_cms", lambda m: 100 * m["vel2d"]["rmse"]),
    ("yaw_rmse_deg", lambda m: np.degrees(m["yaw"]["rmse"])),
    ("nees2d_mean", lambda m: m["nees2d_mean"]),
    ("inside_3sigma_pct", lambda m: 100 * m["inside_3sigma"]),
    ("uwb_only_settled_rmse_cm",
     lambda m: 100 * m["uwb_only_pos2d_settled"]["rmse"] if m["uwb_only_pos2d_settled"] else float("nan")),
    ("nav_delivered_pct", lambda m: live(m, "nav", "delivered")),
    ("uwb_delivered_pct", lambda m: live(m, "uwb", "delivered")),
    ("nav_stamp_err_ms", lambda m: live(m, "nav", "timestamp_error_ms")),
    ("uwb_stamp_err_ms", lambda m: live(m, "uwb", "timestamp_error_ms")),
]


def live(m, stream, key):
    s = m.get("live", {}).get(stream) or {}
    v = s.get(key)
    if v is None:
        return float("nan")
    return 100 * v if key == "delivered" else v["mean_signed"]


def fmt(v):
    return f"{v:.2f}" if isinstance(v, float) else str(v)


def load(dirs):
    runs = []
    for d in dirs:
        p = Path(d) / "metrics.json"
        if p.exists():
            m = json.loads(p.read_text())
            parent = Path(d).resolve().parent
            m["experiment"] = m.get("experiment") or (parent.name if parent.name[:3].isdigit() else None)
            m["_experiment_dir"] = parent if m["experiment"] == parent.name else None
            runs.append(m)
    return runs


def compare(dirs, out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    runs = sorted(load(dirs), key=lambda m: (m["scenario"], m["mode"], m.get("tag") or "", m["seed"]))
    if not runs:
        raise SystemExit("no metrics.json in the given directories (run evaluate.py first)")
    rows = [{name: f(m) for name, f in COLUMNS} for m in runs]

    with open(out / "runs.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[c for c, _ in COLUMNS])
        w.writeheader()
        w.writerows({k: fmt(v) for k, v in r.items()} for r in rows)

    def label(r):
        exp = f"#{r['experiment'].split('_')[0]}" if r["experiment"] else r["commit"]
        return " ".join(x for x in [exp, r["mode"], r["tag"]] if x)

    scenarios = sorted({r["scenario"] for r in rows})
    common = {}
    for sc in scenarios:
        seeds_by_group = defaultdict(set)
        for r in rows:
            if r["scenario"] == sc:
                seeds_by_group[label(r)].add(r["seed"])
        common[sc] = set.intersection(*seeds_by_group.values())
    all_seeds = defaultdict(lambda: defaultdict(list))
    groups = defaultdict(lambda: defaultdict(list))
    uwb_ref = defaultdict(dict)
    for r in rows:
        all_seeds[label(r)][r["scenario"]].append(r)
        if r["seed"] in common[r["scenario"]]:
            groups[label(r)][r["scenario"]].append(r)
            uwb_ref[r["scenario"]][r["seed"]] = r["uwb_only_settled_rmse_cm"]
    uwb_ref = {sc: list(v.values()) for sc, v in uwb_ref.items()}

    md = []
    for exp_dir in sorted({m["_experiment_dir"] for m in runs if m["_experiment_dir"]}):
        md += [f"**{exp_dir.name}**", ""] + (experiments.notes(exp_dir) or ["(no notes)"]) + [""]
    md += ["| group | scenario | seeds | settled 2D RMSE (cm) | p95 (cm) | z RMSE (cm) | yaw RMSE (°) "
          "| NEES | in 3σ (%) | UWB-only RMSE (cm) |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for label, by_sc in all_seeds.items():
        for sc in scenarios:
            rs = by_sc.get(sc)
            if not rs:
                continue

            def mean(k):
                return np.nanmean([r[k] for r in rs])
            md.append(f"| {label} | {sc} | {','.join(str(r['seed']) for r in rs)} | {mean('settled_rmse_cm'):.1f} | "
                      f"{mean('settled_p95_cm'):.1f} | {mean('z_rmse_cm'):.1f} | {mean('yaw_rmse_deg'):.2f} | "
                      f"{mean('nees2d_mean'):.2f} | {mean('inside_3sigma_pct'):.1f} | "
                      f"{mean('uwb_only_settled_rmse_cm'):.1f} |")
    md += ["", "rmse.png compares the seeds every group has: " + ", ".join(
        f"{sc} {sorted(common[sc]) or 'none in common'}" for sc in scenarios) + "."]
    (out / "summary.md").write_text("\n".join(md) + "\n")

    labels = list(groups) + ["UWB only"]
    width = 0.8 / len(labels)
    x = np.arange(len(scenarios))
    fig, ax = plt.subplots(figsize=(max(6, 1.6 * len(scenarios) * len(labels) ** 0.5), 4.5))
    for i, label in enumerate(labels):
        vals = [[r["settled_rmse_cm"] for r in groups[label].get(sc, [])] if label != "UWB only"
                else uwb_ref[sc] for sc in scenarios]
        mean = np.array([np.nanmean(v) if v else np.nan for v in vals])
        lo = np.array([mean[j] - np.nanmin(v) if v else 0 for j, v in enumerate(vals)])
        hi = np.array([np.nanmax(v) - mean[j] if v else 0 for j, v in enumerate(vals)])
        ax.bar(x + (i - (len(labels) - 1) / 2) * width, mean, width, yerr=[lo, hi], capsize=3,
               label=label, color="0.75" if label == "UWB only" else None)
    ax.set_xticks(x, scenarios)
    ax.set_ylabel("2D position RMSE after settling (cm)")
    ax.set_title("Filter error per scenario (mean over the seeds all groups share, bars: min..max)")
    ax.legend(fontsize=8)
    ax.grid(axis="y", alpha=0.3)
    fig.savefig(out / "rmse.png", dpi=130, bbox_inches="tight")
    plt.close(fig)
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(experiments.DEFAULT_ROOT / "comparisons" / f"{datetime.now():%Y-%m-%d_%H%M%S}"))
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    print(compare(a.dirs, a.out))
