#!/usr/bin/env python3
"""Plots of UWB ranging sessions recorded by scripts/uwb_ranging.escript.

Usage:
    python3 plots/uwb_ranging.py [SESSION_DIR ...] [--out DIR] [--outlier-m M] [--show]

With no SESSION_DIR, the latest session in data/uwb_ranging/ that has at
least one successful range. Several sessions (at most 3) are overlaid, one
colour each.

Writes, in --out (default: the session's folder, or
data/uwb_ranging/combined/ for several sessions):
    ranging_accuracy.png  raw range and error against the true distance,
                          with a linear fit
    ranging_samples.png   every range of every point over time, to spot
                          drift and outliers
and prints a per-point table and the fitted calibration.

Outliers: a range more than --outlier-m (default 0.5 m) from its point's
median. They are left out of the statistics, the fit and the axis scales,
and listed in the table and on the plots.

The fit is  raw = a * true + b  over all non-outlier ranges. Inverted, it
is the per-anchor correction of hera_uwb (Range = Scale * Raw + Bias):
Scale = 1/a, Bias = -b/a.

A second fit, error = c0 + c1 * ln(true), follows the DW1000's bias that
depends on the received power (which falls with 20 log10 of the distance):
the error is largest close up and shrinks with distance, which a straight
line can't follow over a wide range of distances.

Needs numpy and matplotlib.
"""

import argparse
import csv
import json
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "uwb_ranging"

# Reference palette (light mode). Scatter-type charts compare every pair of
# colours, and only the first three categorical slots stay distinguishable
# under colour-vision deficiency, hence at most three sessions.
SURFACE = "#fcfcfb"
TEXT = "#0b0b0b"
TEXT_2 = "#52514e"
MUTED = "#8a8984"
GRID = "#e6e5e1"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a"]
MAX_SESSIONS = len(SERIES)

plt.rcParams.update({
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID,
    "axes.labelcolor": TEXT_2,
    "axes.titlecolor": TEXT,
    "axes.titlesize": 11,
    "axes.labelsize": 9,
    "axes.grid": True,
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "xtick.color": TEXT_2,
    "ytick.color": TEXT_2,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "legend.fontsize": 8,
    "legend.frameon": False,
    "text.color": TEXT,
    "font.size": 9,
})


# --- Loading -------------------------------------------------------------

def load_session(path):
    path = Path(path)
    meta = json.loads((path / "meta.json").read_text())
    notes = {}
    with open(path / "points.csv", newline="") as f:
        for row in csv.DictReader(f):
            notes[int(row["point"])] = row["note"]
    points = {}
    with open(path / "ranges.csv", newline="") as f:
        for row in csv.DictReader(f):
            p = int(row["point"])
            pt = points.setdefault(p, {
                "point": p, "true": float(row["true_distance_m"]),
                "note": notes.get(p, ""), "n": 0, "t": [], "d": [], "failed": {}})
            pt["n"] += 1
            if row["status"] == "ok":
                pt["t"].append(int(row["host_time_ms"]))
                pt["d"].append(float(row["raw_distance_m"]))
            else:
                pt["failed"][row["status"]] = pt["failed"].get(row["status"], 0) + 1
    for pt in points.values():
        pt["t"] = np.array(pt["t"], dtype=float)
        pt["d"] = np.array(pt["d"], dtype=float)
    comment = meta.get("options", {}).get("comment", "")
    label = path.name + (f" · {comment}" if comment else "")
    return {"path": path, "label": label, "meta": meta,
            "points": [points[k] for k in sorted(points)]}


def latest_session():
    for d in sorted(DATA.glob("*/"), key=lambda p: p.stat().st_mtime, reverse=True):
        if (d / "ranges.csv").exists():
            with open(d / "ranges.csv", newline="") as f:
                if any(r["status"] == "ok" for r in csv.DictReader(f)):
                    return d
    sys.exit(f"No session with a successful range in {DATA}")


def split_outliers(pt, limit):
    """Marks ranges more than `limit` m from the point's median."""
    if len(pt["d"]) == 0:
        pt["inlier"] = np.array([], dtype=bool)
        return
    med = np.median(pt["d"])
    pt["inlier"] = np.abs(pt["d"] - med) <= limit


# --- Statistics ----------------------------------------------------------

def point_stats(pt):
    d = pt["d"][pt["inlier"]]
    if len(d) == 0:
        return None
    return {"median": float(np.median(d)), "mean": float(np.mean(d)),
            "std": float(np.std(d, ddof=1)) if len(d) > 1 else 0.0,
            "ok": len(pt["d"]), "outliers": int((~pt["inlier"]).sum())}


def fit(sessions):
    x = np.concatenate([np.full(pt["inlier"].sum(), pt["true"])
                        for s in sessions for pt in s["points"]])
    y = np.concatenate([pt["d"][pt["inlier"]] for s in sessions for pt in s["points"]])
    if len(np.unique(x)) < 2:
        return None
    a, b = np.polyfit(x, y, 1)
    resid = y - (a * x + b)
    return {"a": a, "b": b, "rms": float(np.sqrt(np.mean(resid ** 2))), "n": len(x)}


def fit_log(sessions):
    """error = raw - true = c0 + c1 * ln(true), over the non-outlier ranges."""
    x = np.concatenate([np.full(pt["inlier"].sum(), pt["true"])
                        for s in sessions for pt in s["points"]])
    y = np.concatenate([pt["d"][pt["inlier"]] for s in sessions for pt in s["points"]])
    keep = x > 0
    x, y = x[keep], y[keep]
    if len(np.unique(x)) < 2:
        return None
    c1, c0 = np.polyfit(np.log(x), y - x, 1)
    resid = (y - x) - (c0 + c1 * np.log(x))
    return {"c0": c0, "c1": c1, "rms": float(np.sqrt(np.mean(resid ** 2))), "n": len(x)}


def print_table(sessions, limit):
    for s in sessions:
        print(f"\n{s['label']}")
        print(f"{'point':>5} {'true m':>7} {'ok/n':>8} {'outl.':>5} {'median m':>9} "
              f"{'std cm':>7} {'err cm':>7}  note / failures")
        for pt in s["points"]:
            st = point_stats(pt)
            fails = ", ".join(f"{k}×{v}" for k, v in pt["failed"].items())
            extra = "; ".join(x for x in [pt["note"], fails] if x)
            if st is None:
                print(f"{pt['point']:>5} {pt['true']:>7.3f} {0:>3}/{pt['n']:<4} {'-':>5} "
                      f"{'-':>9} {'-':>7} {'-':>7}  {extra}")
                continue
            print(f"{pt['point']:>5} {pt['true']:>7.3f} {st['ok']:>3}/{pt['n']:<4} "
                  f"{st['outliers']:>5} {st['median']:>9.3f} {st['std'] * 100:>7.1f} "
                  f"{(st['median'] - pt['true']) * 100:>+7.1f}  {extra}")
            for t, d in zip(pt["t"][~pt["inlier"]], pt["d"][~pt["inlier"]]):
                print(f"{'':>14}outlier {d:.3f} m (more than {limit} m from the median)")


# --- Plots ---------------------------------------------------------------

def jitter(n, width, seed):
    return np.random.default_rng(seed).uniform(-width, width, n)


def plot_accuracy(sessions, fitted, fitted_log, out, limit):
    fig, (ax1, ax2) = plt.subplots(2, 1, sharex=True, figsize=(7.5, 8),
                                   gridspec_kw={"height_ratios": [3, 2], "hspace": 0.22})
    trues = [pt["true"] for s in sessions for pt in s["points"] if pt["inlier"].any()]
    span = max(trues) - min(trues) if len(trues) > 1 else 1.0
    jw = 0.012 * max(span, 0.5)
    outliers = []

    for i, s in enumerate(sessions):
        c = SERIES[i]
        # Sessions side by side, so equal medians at the same distance don't hide.
        dodge = (i - (len(sessions) - 1) / 2) * 2.5 * jw
        for k, pt in enumerate(s["points"]):
            inl = pt["inlier"]
            if not inl.any():
                continue
            d = pt["d"][inl]
            xm = pt["true"] + dodge
            x = xm + jitter(len(d), jw, seed=1000 * i + k)
            st = point_stats(pt)
            ax1.scatter(x, d, s=6, color=c, alpha=0.25, linewidths=0, zorder=2)
            ax2.scatter(x, (d - pt["true"]) * 100, s=6, color=c, alpha=0.25,
                        linewidths=0, zorder=2)
            for ax, m, e in [(ax1, st["median"], st["std"]),
                             (ax2, (st["median"] - pt["true"]) * 100, st["std"] * 100)]:
                ax.errorbar(xm, m, yerr=e, fmt="o", ms=6, color=c, mec=SURFACE,
                            mew=1.5, elinewidth=1.5, capsize=0, zorder=4)
            outliers += [(pt["true"], o) for o in pt["d"][~inl]]
        # Legend entry for the session (one per colour).
        ax1.errorbar([], [], yerr=[], fmt="o", ms=6, color=c, mec=SURFACE, mew=1.5,
                     elinewidth=1.5, label=s["label"] + "  (median ± std, dots: ranges)")

    lo, hi = min(trues) - 0.1 * max(span, 0.5), max(trues) + 0.1 * max(span, 0.5)
    xs = np.array([lo, hi])
    ax1.plot(xs, xs, color=MUTED, lw=1.2, ls=(0, (4, 3)), zorder=1, label="raw = true")
    ax2.axhline(0, color=MUTED, lw=1.2, ls=(0, (4, 3)), zorder=1)
    if fitted:
        a, b = fitted["a"], fitted["b"]
        ax1.plot(xs, a * xs + b, color=TEXT_2, lw=1.5, zorder=3,
                 label=f"fit: raw = {a:.3f}·true {b:+.3f} m  (RMS {fitted['rms'] * 100:.1f} cm)")
        ax2.plot(xs, (a * xs + b - xs) * 100, color=TEXT_2, lw=1.5, zorder=3)
    if fitted_log:
        c0, c1 = fitted_log["c0"], fitted_log["c1"]
        xl = np.linspace(max(lo, min(trues) / 2), hi, 200)
        el = c0 + c1 * np.log(xl)
        ax1.plot(xl, xl + el, color=TEXT, lw=1.5, ls=(0, (1, 1.5)), zorder=3,
                 label=f"fit: raw − true = {c0 * 100:+.1f} {c1 * 100:+.1f}·ln(true) cm  "
                       f"(RMS {fitted_log['rms'] * 100:.1f} cm)")
        ax2.plot(xl, el * 100, color=TEXT, lw=1.5, ls=(0, (1, 1.5)), zorder=3)
    ax1.set_xlim(lo, hi)
    # sharex hides the top panel's tick labels: show them on both.
    ax1.tick_params(labelbottom=True)
    ax1.set_xlabel("true distance, measured by hand (m)")

    ax1.set_ylabel("raw range (m)")
    ax2.set_ylabel("error, raw − true (cm)")
    ax2.set_xlabel("true distance, measured by hand (m)")
    ax1.set_title("UWB DS-TWR ranging, uncalibrated", loc="left")
    ax1.legend(loc="upper left")
    if outliers:
        txt = (f"{len(outliers)} outlier(s) more than {limit} m from their point's median, "
               "not shown: " + ", ".join(f"{o:.2f} m at {t:.2f} m" for t, o in outliers[:4])
               + (" …" if len(outliers) > 4 else ""))
        ax2.annotate(txt, xy=(0, -0.28), xycoords="axes fraction", fontsize=8,
                     color=TEXT_2, va="top")
    fig.savefig(out / "ranging_accuracy.png", dpi=150, bbox_inches="tight")
    plt.close(fig)


def plot_samples(sessions, out, limit):
    panels = sorted(((i, s, pt) for i, s in enumerate(sessions) for pt in s["points"]
                     if pt["inlier"].any()),
                    key=lambda x: (x[2]["true"], x[0], x[2]["point"]))
    if not panels:
        return
    # Same vertical span in every panel, so the noise compares at a glance.
    half = max(np.max(np.abs(pt["d"][pt["inlier"]] - np.median(pt["d"][pt["inlier"]])))
               for _, _, pt in panels) * 1.15
    half = max(half, 0.05)
    cols = min(3, len(panels))
    rows = -(-len(panels) // cols)
    fig, axes = plt.subplots(rows, cols, figsize=(3.6 * cols, 2.6 * rows), squeeze=False)
    for ax in axes.flat[len(panels):]:
        ax.set_visible(False)
    for ax, (i, s, pt) in zip(axes.flat, panels):
        c = SERIES[i]
        t = (pt["t"] - pt["t"].min()) / 1000
        inl = pt["inlier"]
        med = np.median(pt["d"][inl])
        ax.plot(t[inl], pt["d"][inl], color=c, lw=1, alpha=0.6, zorder=2)
        ax.scatter(t[inl], pt["d"][inl], s=8, color=c, linewidths=0, zorder=3)
        ax.axhline(med, color=TEXT_2, lw=1, zorder=1)
        ax.set_ylim(med - half, med + half)
        # Outliers: a marker on the top or bottom edge, with the value.
        for to, do in zip(t[~inl], pt["d"][~inl]):
            y = med + half * (0.92 if do > med else -0.92)
            ax.scatter([to], [y], marker="^" if do > med else "v", s=36, color=TEXT,
                       zorder=4)
            ax.annotate(f"{do:.2f} m", (to, y), xytext=(5, -3), textcoords="offset points",
                        fontsize=7, color=TEXT)
        st = point_stats(pt)
        title = (f"{pt['true']:.2f} m true · point {pt['point']} · {st['ok']}/{pt['n']} ok"
                 + (f" · {st['outliers']} outl." if st["outliers"] else ""))
        if len(sessions) > 1:
            title = f"{s['path'].name}\n" + title
        ax.set_title(title, loc="left", fontsize=9, pad=13)
        ax.annotate(f"median {med:.3f} m, std {st['std'] * 100:.1f} cm",
                    xy=(0, 1.0), xycoords="axes fraction", xytext=(0, 2),
                    textcoords="offset points", fontsize=7, color=TEXT_2, va="bottom")
    for ax in axes[:, 0]:
        ax.set_ylabel("raw range (m)")
    for ax in axes[-1, :]:
        ax.set_xlabel("time since point start (s)")
    fig.suptitle(f"Every range per point (same {2 * half * 100:.0f} cm span in each panel; "
                 f"outliers > {limit} m from the median on the edge)",
                 x=0.01, ha="left", fontsize=10, color=TEXT)
    fig.tight_layout()
    fig.savefig(out / "ranging_samples.png", dpi=150, bbox_inches="tight")
    plt.close(fig)


# --- Main ----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("sessions", nargs="*", help="session folders (default: the latest)")
    ap.add_argument("--out", help="output folder")
    ap.add_argument("--outlier-m", type=float, default=0.5,
                    help="distance from a point's median beyond which a range is an outlier (m)")
    args = ap.parse_args()

    paths = [Path(p) for p in args.sessions] or [latest_session()]
    if len(paths) > MAX_SESSIONS:
        sys.exit(f"At most {MAX_SESSIONS} sessions per plot (colours stay distinguishable "
                 "only up to three); plot them in groups.")
    sessions = [load_session(p) for p in paths]
    for s in sessions:
        for pt in s["points"]:
            split_outliers(pt, args.outlier_m)

    pairs = {(s["meta"]["tag"]["node"], s["meta"]["anchor"]["node"]) for s in sessions}
    if len(pairs) > 1:
        print("WARNING: the sessions use different tag/anchor pairs, so one fit over "
              f"all of them mixes their offsets: {sorted(pairs)}")

    out = Path(args.out) if args.out else (paths[0] if len(paths) == 1 else DATA / "combined")
    out.mkdir(parents=True, exist_ok=True)

    print_table(sessions, args.outlier_m)
    fitted = fit(sessions)
    if fitted:
        a, b = fitted["a"], fitted["b"]
        print(f"\nFit over {fitted['n']} ranges: raw = {a:.4f} * true {b:+.4f} m, "
              f"residual RMS {fitted['rms'] * 100:.1f} cm")
        print(f"hera_uwb correction (Range = Scale * Raw + Bias): "
              f"{{{1 / a:.4f}, {-b / a:.4f}}}")
    else:
        print("\nFit needs at least two distinct true distances.")
    fitted_log = fit_log(sessions)
    if fitted_log:
        print(f"Log fit over {fitted_log['n']} ranges: raw - true = "
              f"{fitted_log['c0'] * 100:+.2f} {fitted_log['c1'] * 100:+.2f} * ln(true) cm, "
              f"residual RMS {fitted_log['rms'] * 100:.1f} cm")

    plot_accuracy(sessions, fitted, fitted_log, out, args.outlier_m)
    plot_samples(sessions, out, args.outlier_m)
    print(f"\nPlots in {out}/: ranging_accuracy.png, ranging_samples.png")


if __name__ == "__main__":
    main()
