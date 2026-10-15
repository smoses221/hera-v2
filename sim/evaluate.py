"""Error of one run against its ground truth: metrics.json + plots.

The estimate is what a consumer of the filter would see: held from one
update to the next (zero-order hold), sampled on a uniform grid (GRID_HZ)
and compared with the truth at the same time. Metrics are given over the
whole run and after SETTLE_S (once the initial transient is gone).

Two references are evaluated the same way, so the filter's gain is visible:
  - UWB only: two-circle intersection of the latest range to each anchor,
    on the tag's side of the anchor line;
  - NAV only: the same filter fed only the NAV samples, no UWB correction
    (estimate_nav_only.csv, sim_replay:nav_only/1). Its error grows with
    time, so it is also given at fixed times (NAV_ONLY_AT_S).

Usage: python3 sim/evaluate.py <run_dir> [<run_dir> ...]
"""

import json
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

GRID_HZ = 100.0
SETTLE_S = 5.0
CHI2_2D_3SIGMA = 9.0  # NEES bound for 2 dof at ~98.9 % (the 2D "3 sigma" ellipse)
UWB_PAIR_MAX_S = 1.5  # max age of the other anchor's range in the UWB-only fix
NAV_ONLY_AT_S = [1, 2, 5, 10, 30]  # times at which the NAV-only error is reported (+ the end)


def load_csv(path):
    """Columns of a CSV with a header, as a dict of arrays (strings stay strings)."""
    with open(path) as f:
        header = f.readline().strip().split(",")
    data = np.genfromtxt(path, delimiter=",", skip_header=1, dtype=None, encoding="utf-8",
                         names=header, ndmin=1)
    return {name: data[name] for name in header}


def wrap(a):
    return (a + np.pi) % (2 * np.pi) - np.pi


def hold(t_src, values, t_grid):
    """Zero-order hold of values (rows at t_src) onto t_grid (t_grid >= t_src[0])."""
    idx = np.searchsorted(t_src, t_grid, side="right") - 1
    return values[np.clip(idx, 0, len(t_src) - 1)]


def stats(e):
    e = np.abs(e)
    return {"rmse": float(np.sqrt(np.mean(e**2))), "mean": float(np.mean(e)),
            "median": float(np.median(e)), "p95": float(np.percentile(e, 95)),
            "max": float(np.max(e)), "final": float(e[-1])}


def uwb_only(uwb, anchors, side):
    """Fixes from the latest range to each of two anchors: [t, x, y] rows."""
    (i1, a1), (i2, a2) = sorted(((int(k), np.array(v[:2])) for k, v in anchors.items()))
    d = np.linalg.norm(a2 - a1)
    ex = (a2 - a1) / d
    ey = np.array([-ex[1], ex[0]]) * side
    last, fixes = {}, []
    for t, idx, r in zip(uwb["t"], uwb["anchor"].astype(int), uwb["range"]):
        last[idx] = (t, r)
        if i1 in last and i2 in last and t - min(last[i1][0], last[i2][0]) <= UWB_PAIR_MAX_S:
            r1, r2 = last[i1][1], last[i2][1]
            x = (r1**2 - r2**2 + d**2) / (2 * d)
            y = np.sqrt(max(r1**2 - x**2, 0.0))  # no intersection: closest point on the line
            fixes.append([t, *(a1 + x * ex + y * ey)])
    return np.array(fixes).reshape(-1, 3)


def footnote(fig, meta, mode):
    git = meta.get("git", {})
    exp = f"exp {meta['experiment'].split('_')[0]} | " if meta.get("experiment") else ""
    fig.text(0.01, 0.005,
             f"{exp}{meta['scenario']} | seed {meta['seed']} | {mode} | {git.get('describe', '?')}"
             f" | gen v{meta['generator_version']}",
             fontsize=7, color="0.4", ha="left", va="bottom")


def experiment_of(run):
    """The numbered experiment folder a run sits in (sim/experiments.py), if any."""
    parent = Path(run).resolve().parent.name
    return parent if parent[:3].isdigit() else None


def evaluate(run_dir, plots=True):
    run = Path(run_dir)
    meta = json.loads((run / "meta.json").read_text())
    erl = json.loads((run / "erl_meta.json").read_text())
    mode = erl.get("mode", "offline")
    tr = load_csv(run / "truth.csv")
    est = load_csv(run / "estimate.csv")
    uwb = load_csv(run / "uwb.csv")

    t_est = est["t"].astype(float)
    t_grid = np.arange(max(t_est[0], 0.0), meta["duration"], 1.0 / GRID_HZ)
    cols = ["px", "py", "pz", "vx", "vy", "pxx", "pxy", "pyy", "pzz", "yaw"]
    e = {c: hold(t_est, est[c].astype(float), t_grid) for c in cols}
    truth = {c: np.interp(t_grid, tr["t"], tr[c]) for c in ["px", "py", "pz", "vx", "vy", "yaw"]}

    ex, ey, ez = e["px"] - truth["px"], e["py"] - truth["py"], e["pz"] - truth["pz"]
    e2d = np.hypot(ex, ey)
    ev = np.hypot(e["vx"] - truth["vx"], e["vy"] - truth["vy"])
    eyaw = wrap(e["yaw"] - truth["yaw"])
    det = e["pxx"] * e["pyy"] - e["pxy"] ** 2
    nees = (e["pyy"] * ex**2 - 2 * e["pxy"] * ex * ey + e["pxx"] * ey**2) / det
    # 3 sigma along the covariance's major axis, as a radial bound
    lmax = 0.5 * (e["pxx"] + e["pyy"]) + np.sqrt(0.25 * (e["pxx"] - e["pyy"]) ** 2 + e["pxy"] ** 2)
    bound3 = 3.0 * np.sqrt(lmax)

    side = 1.0 if meta["init"]["x0"][3] >= 0 else -1.0
    fixes = uwb_only(uwb, meta["anchors"], side)
    u_grid = t_grid[t_grid >= fixes[0, 0]] if len(fixes) else np.array([])
    u_xy = hold(fixes[:, 0], fixes[:, 1:], u_grid) if len(fixes) else np.zeros((0, 2))
    u_err = np.hypot(u_xy[:, 0] - np.interp(u_grid, tr["t"], tr["px"]),
                     u_xy[:, 1] - np.interp(u_grid, tr["t"], tr["py"]))

    nav = None
    if (run / "estimate_nav_only.csv").exists():
        n_est = load_csv(run / "estimate_nav_only.csv")
        n_t = n_est["t"].astype(float)
        n_xy = np.column_stack([hold(n_t, n_est[c].astype(float), t_grid) for c in ["px", "py"]])
        n_err = np.hypot(n_xy[:, 0] - truth["px"], n_xy[:, 1] - truth["py"])
        n_ez = hold(n_t, n_est["pz"].astype(float), t_grid) - truth["pz"]
        nav = {"xy": n_xy, "err": n_err}

    settled = t_grid >= SETTLE_S
    metrics = {
        "experiment": meta.get("experiment") or experiment_of(run),
        "scenario": meta["scenario"], "seed": meta["seed"], "mode": mode, "tag": meta.get("tag"),
        "git": meta.get("git", {}), "backend": erl.get("backend"),
        "module_md5": erl.get("module_md5"), "filter_cfg": erl.get("filter_cfg"),
        "grid_hz": GRID_HZ, "settle_s": SETTLE_S,
        "pos2d": stats(e2d), "pos2d_settled": stats(e2d[settled]),
        "x": stats(ex), "y": stats(ey), "z": stats(ez),
        "vel2d": stats(ev), "yaw": stats(eyaw),
        "nees2d_mean": float(np.mean(nees)),
        "inside_3sigma": float(np.mean(nees <= CHI2_2D_3SIGMA)),
        "uwb_only_pos2d": stats(u_err) if len(u_err) else None,
        "uwb_only_pos2d_settled": stats(u_err[u_grid >= SETTLE_S]) if len(u_err) else None,
        "nav_only": {
            "pos2d": stats(nav["err"]), "z": stats(n_ez),
            "pos2d_at_s": {f"{s:g}": float(np.interp(s, t_grid, nav["err"]))
                           for s in NAV_ONLY_AT_S if s < t_grid[-1]}
                          | {"end": float(nav["err"][-1])},
        } if nav else None,
        "updates": {"total": int(len(t_est)),
                    "nav": int(np.sum(est["src"] == "nav")), "uwb": int(np.sum(est["src"] == "uwb"))},
        "late": erl.get("late"), "filter_wall_us": erl.get("filter_wall_us"),
    }
    if mode == "live":
        metrics["live"] = live_metrics(run, erl)
    (run / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")

    if plots:
        plot(run, meta, mode, tr, est, fixes, t_grid, ex, ey, ez, e2d, eyaw, bound3, e,
             u_grid, u_err, metrics, nav)
    return metrics


def live_metrics(run, erl):
    """Delivery and timestamp error of the live path, per stream."""
    rec = load_csv(run / "received.csv")
    out = {"seq_gaps": erl.get("seq_gaps"), "foreign_nodes": erl.get("foreign_nodes"),
           "polls": erl.get("polls")}
    for name in ["nav", "uwb"]:
        sent_path = run / f"sent_{name}.csv"
        if not sent_path.exists():
            out[name] = {"sent": None}
            continue
        sent = load_csv(sent_path)
        m = rec["name"] == name
        seq_r, t_r, wall_r = rec["seq"][m].astype(int), rec["t"][m].astype(float), rec["wall_ms"][m]
        t_true = dict(zip(sent["seq"].astype(int), sent["t"].astype(float)))
        wall_s = dict(zip(sent["seq"].astype(int), sent["wall_ms"]))
        known = np.array([s in t_true for s in seq_r], dtype=bool)
        stamp_err = np.array([t - t_true[s] for s, t in zip(seq_r[known], t_r[known])]) * 1000
        delay = np.array([w - wall_s[s] for s, w in zip(seq_r[known], wall_r[known])], dtype=float)
        out[name] = {
            "sent": int(len(sent["seq"])), "received": int(m.sum()),
            "delivered": float(m.sum() / max(len(sent["seq"]), 1)),
            "timestamp_error_ms": stats(stamp_err) | {"mean_signed": float(np.mean(stamp_err))}
            if len(stamp_err) else None,
            "sent_to_processed_ms": stats(delay) if len(delay) else None,
        }
    return out


def plot(run, meta, mode, tr, est, fixes, t_grid, ex, ey, ez, e2d, eyaw, bound3, e,
         u_grid, u_err, metrics, nav=None):
    anchors = np.array([v for _, v in sorted(meta["anchors"].items(), key=lambda kv: int(kv[0]))])
    title = f"{meta['scenario']} (seed {meta['seed']}, {mode})"

    fig, ax = plt.subplots(figsize=(7, 6))
    if len(fixes):
        ax.plot(fixes[:, 1], fixes[:, 2], ".", ms=3, color="0.6", label="UWB only")
    ax.plot(tr["px"], tr["py"], "k-", lw=1.5, label="truth")
    ax.plot(e["px"], e["py"], "-", lw=1, color="tab:blue", label="filter")
    ax.plot(anchors[:, 0], anchors[:, 1], "r^", ms=10, label="anchors")
    ax.plot(tr["px"][0], tr["py"][0], "ko", mfc="none", ms=8, label="start")
    # The view fits truth, filter and anchors; the NAV-only path may leave it.
    pts = np.vstack([np.column_stack([tr["px"], tr["py"]]), np.column_stack([e["px"], e["py"]]),
                     anchors[:, :2]])
    lo, hi = pts.min(axis=0) - 0.3, pts.max(axis=0) + 0.3
    if nav:
        inside = np.all((nav["xy"] >= lo) & (nav["xy"] <= hi), axis=1)
        leaves = f", leaves the view at {t_grid[np.argmin(inside)]:.1f} s" if not inside.all() else ""
        ax.plot(nav["xy"][:, 0], nav["xy"][:, 1], "-", lw=1, color="tab:red", alpha=0.7,
                label=f"NAV only{leaves}")
    ax.set_xlim(lo[0], hi[0])
    ax.set_ylim(lo[1], hi[1])
    ax.set_aspect("equal")
    ax.set_xlabel("x (m)")
    ax.set_ylabel("y (m)")
    ax.set_title(f"Trajectory: {title}")
    ax.legend(fontsize=8, loc="upper left", bbox_to_anchor=(1.02, 1.0))
    ax.grid(alpha=0.3)
    footnote(fig, meta, mode)
    fig.savefig(run / "trajectory.png", dpi=130, bbox_inches="tight")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(10, 4))
    if len(u_err):
        ax.plot(u_grid, u_err, color="0.7", lw=0.8, label="UWB only")
    ax.plot(t_grid, e2d, color="tab:blue", lw=1, label="filter |error|")
    ax.plot(t_grid, bound3, "--", color="tab:orange", lw=1, label="filter 3σ (major axis)")
    top = 1.05 * max([e2d.max(), bound3[t_grid >= 1.0].max()] + ([u_err.max()] if len(u_err) else []))
    if nav:
        ax.plot(t_grid, nav["err"], color="tab:red", lw=1, alpha=0.7, label="NAV only (see drift.png)")
    ax.set_ylim(0, top)
    p = metrics["pos2d_settled"]
    ax.set_title(f"2D position error: {title}. After {SETTLE_S:g} s: RMSE {p['rmse']*100:.1f} cm, "
                 f"p95 {p['p95']*100:.1f} cm")
    ax.set_xlabel("t (s)")
    ax.set_ylabel("error (m)")
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    footnote(fig, meta, mode)
    fig.savefig(run / "error_time.png", dpi=130, bbox_inches="tight")
    plt.close(fig)

    if nav:
        fig, ax = plt.subplots(figsize=(10, 4))
        ax.semilogy(t_grid, np.maximum(nav["err"], 1e-4), color="tab:red", lw=1, label="NAV only")
        if len(u_err):
            ax.semilogy(u_grid, np.maximum(u_err, 1e-4), color="0.6", lw=0.8, label="UWB only")
        ax.semilogy(t_grid, np.maximum(e2d, 1e-4), color="tab:blue", lw=1, label="filter (NAV + UWB)")
        at = metrics["nav_only"]["pos2d_at_s"]
        ax.set_title(f"2D position error, log scale: {title}. NAV only: "
                     + ", ".join(f"{v*100:.0f} cm at {k} s" if k != "end" else f"{v:.2f} m at the end"
                                 for k, v in at.items() if k in ("1", "10", "end")))
        ax.set_xlabel("t (s)")
        ax.set_ylabel("error (m)")
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3, which="both")
        footnote(fig, meta, mode)
        fig.savefig(run / "drift.png", dpi=130, bbox_inches="tight")
        plt.close(fig)

    sig = {"x": np.sqrt(e["pxx"]), "y": np.sqrt(e["pyy"]), "z": np.sqrt(e["pzz"])}
    fig, axs = plt.subplots(4, 1, figsize=(10, 9), sharex=True)
    for ax, (name, err) in zip(axs, [("x", ex), ("y", ey), ("z", ez)]):
        ax.fill_between(t_grid, -3 * sig[name], 3 * sig[name], color="tab:orange", alpha=0.2,
                        label="±3σ")
        ax.plot(t_grid, err, lw=0.8, color="tab:blue")
        ax.set_ylabel(f"{name} error (m)")
        ax.grid(alpha=0.3)
    axs[0].legend(fontsize=8)
    axs[3].plot(t_grid, np.degrees(eyaw), lw=0.8, color="tab:purple")
    axs[3].set_ylabel("yaw error (°)")
    axs[3].set_xlabel("t (s)")
    axs[3].grid(alpha=0.3)
    axs[0].set_title(f"Per-axis errors: {title}")
    footnote(fig, meta, mode)
    fig.savefig(run / "error_axes.png", dpi=130, bbox_inches="tight")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(6, 4))
    for err, label, color in [(e2d, "filter", "tab:blue"), (u_err, "UWB only", "0.5")]:
        if len(err):
            s = np.sort(err)
            ax.plot(s, np.arange(1, len(s) + 1) / len(s), color=color, label=label)
    ax.set_xlabel("2D position error (m)")
    ax.set_ylabel("fraction of time")
    ax.set_title(f"Error CDF: {title}")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    footnote(fig, meta, mode)
    fig.savefig(run / "error_cdf.png", dpi=130, bbox_inches="tight")
    plt.close(fig)


def summary_line(m):
    p, s = m["pos2d"], m["pos2d_settled"]
    u = m["uwb_only_pos2d_settled"] or {"rmse": float("nan")}
    return (f"{m['scenario']:>14} seed {m['seed']:<3} {m['mode']:<7} "
            f"2D RMSE {p['rmse']*100:6.1f} cm (settled {s['rmse']*100:6.1f}, p95 {s['p95']*100:6.1f}, "
            f"UWB-only {u['rmse']*100:6.1f})  z RMSE {m['z']['rmse']*100:5.1f} cm  "
            f"in 3σ {m['inside_3sigma']*100:5.1f} %"
            + (f"  NAV-only {m['nav_only']['pos2d_at_s'].get('10', float('nan'))*100:.0f} cm at 10 s, "
               f"{m['nav_only']['pos2d_at_s']['end']:.2f} m at end" if m.get("nav_only") else ""))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for d in sys.argv[1:]:
        print(summary_line(evaluate(d)))
