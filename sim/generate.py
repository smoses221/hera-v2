"""Seeded generation of one simulated experiment: ground truth + NAV + UWB.

Writes into the run directory:
  truth.csv  t,px,py,pz,vx,vy,vz,ax,ay,az,yaw,yaw_rate   (200 Hz)
  nav.csv    t,ax,ay,az,gx,gy,gz,mx,my,mz  hera_nav's sample: body frame,
             specific force with gravity (m/s^2), rad/s, uT
  uwb.csv    t,anchor,range                hera_uwb's sample (m)
  meta.json  scenario, seed, every parameter, anchors, filter initial state

The seed fixes everything. Each noise source has its own random stream
(spawned from the seed), so changing e.g. the UWB model leaves the NAV
noise of the same seed unchanged.

Usage: python3 sim/generate.py <scenario> <seed> <out_dir>
"""

import copy
import json
import sys
from pathlib import Path

import numpy as np

from scenarios import DURATION, SCENARIOS, bob

GENERATOR_VERSION = 1
G = 9.80665

DEFAULTS = {
    "duration": DURATION,
    "truth_hz": 1000.0,      # internal grid, derivatives taken on it
    "truth_out_hz": 200.0,   # truth.csv
    # Anchor index -> position (m), as hera_uwb's [{1, 16#0002}, {2, 16#0003}].
    "anchors": {"1": [0.0, 0.0, 0.0], "2": [4.0, 0.0, 0.0]},
    "nav": {
        "odr_hz": 117.7,          # fitted on the board (REDESIGN_LOG), nominal 119
        "acc_noise": 0.02,        # m/s^2, white, per axis
        "acc_bias_sigma": 0.02,   # m/s^2, residual after the six-position calibration
        "gyro_noise": 0.003,      # rad/s, white
        "gyro_bias_sigma": 0.001, # rad/s, residual after the start-up bias
        "mag_world": [20.0, 0.0, -44.0],  # uT, x north-ish, z up
        "mag_noise": 0.3,         # uT
    },
    "uwb": {
        "t_first": 0.25,          # s
        "interval": 0.47,         # s between ranges, measured on the board
        "interval_jitter": 0.005, # s
        "range_noise": 0.03,      # m
        "bias": {"1": 0.0, "2": 0.0},  # m, residual per anchor after correction
        "dropout": 0.003,         # 5 timeouts / 1737 ranges on the board
        "nlos_prob": 0.0,         # outliers, off in the baseline
        "nlos_mean": 0.3,         # m, exponential, positive
    },
    "init": {
        "pos_sigma": 0.10,        # m, error of the known start position (x, y)
        "z_sigma": 0.01,          # m
        "yaw_sigma": 0.02,        # rad
    },
}


def merge(base, over):
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def truth(scenario, params, rng):
    """Truth on the fine grid: dict of arrays."""
    dt = 1.0 / params["truth_hz"]
    t = np.arange(0.0, params["duration"] + dt / 2, dt)
    xy, yaw, with_bob = SCENARIOS[scenario](t, rng)
    z = bob(t, rng) if with_bob else np.zeros(len(t))
    p = np.column_stack([xy, z])
    v = np.gradient(p, dt, axis=0, edge_order=2)
    a = np.gradient(v, dt, axis=0, edge_order=2)
    yaw = np.unwrap(yaw)
    return {"t": t, "p": p, "v": v, "a": a, "yaw": yaw,
            "yaw_rate": np.gradient(yaw, dt, edge_order=2)}


def at(tr, key, ts):
    """Truth `key` linearly interpolated at times ts."""
    x = tr[key]
    if x.ndim == 1:
        return np.interp(ts, tr["t"], x)
    return np.column_stack([np.interp(ts, tr["t"], x[:, i]) for i in range(x.shape[1])])


def nav_samples(tr, p, rng):
    n = p["nav"]
    ts = np.arange(0.0, p["duration"], 1.0 / n["odr_hz"])
    a = at(tr, "a", ts)
    yaw = at(tr, "yaw", ts)
    c, s = np.cos(yaw), np.sin(yaw)

    def to_body(w):  # Rz(yaw)^T * w
        return np.column_stack([c * w[:, 0] + s * w[:, 1], -s * w[:, 0] + c * w[:, 1], w[:, 2]])

    # Biases first, so the streams don't depend on the number of samples.
    acc_bias = rng.normal(0.0, n["acc_bias_sigma"], 3)
    gyro_bias = rng.normal(0.0, n["gyro_bias_sigma"], 3)
    k = len(ts)
    acc = to_body(a + [0.0, 0.0, G]) + acc_bias + rng.normal(0.0, n["acc_noise"], (k, 3))
    gyro = np.column_stack([np.zeros(k), np.zeros(k), at(tr, "yaw_rate", ts)])
    gyro = gyro + gyro_bias + rng.normal(0.0, n["gyro_noise"], (k, 3))
    mag = to_body(np.tile(n["mag_world"], (k, 1))) + rng.normal(0.0, n["mag_noise"], (k, 3))
    rows = np.column_stack([ts, acc, gyro, mag])
    return rows, {"acc_bias": acc_bias.tolist(), "gyro_bias": gyro_bias.tolist()}


def uwb_samples(tr, p, rng):
    u = p["uwb"]
    anchors = sorted(p["anchors"], key=int)
    rows, dropped, t, i = [], 0, u["t_first"], 0
    while t <= p["duration"]:
        idx = anchors[i % len(anchors)]
        # Fixed number of draws per attempt, so the stream stays aligned.
        drop, noise, nlos, nlos_err, jitter = (rng.random(), rng.normal(0.0, u["range_noise"]),
                                               rng.random(), rng.exponential(u["nlos_mean"]),
                                               rng.normal(0.0, u["interval_jitter"]))
        if drop < u["dropout"]:
            dropped += 1
        else:
            true_range = np.linalg.norm(at(tr, "p", np.array([t]))[0] - p["anchors"][idx])
            r = true_range + u["bias"].get(idx, 0.0) + noise
            if nlos < u["nlos_prob"]:
                r += nlos_err
            rows.append([t, int(idx), r])
        t += u["interval"] + jitter
        i += 1
    return np.array(rows), {"uwb_dropped": dropped}


def initial_state(tr, p, rng):
    i = p["init"]
    p0 = tr["p"][0]
    n = rng.normal(0.0, 1.0, 4)
    x0 = [p0[0] + i["pos_sigma"] * n[0], 0.0, 0.0,
          p0[1] + i["pos_sigma"] * n[1], 0.0, 0.0,
          p0[2] + i["z_sigma"] * n[2], 0.0, 0.0]
    return {"t0": 0.0, "x0": [float(v) for v in x0],
            "yaw0": float(tr["yaw"][0] + i["yaw_sigma"] * n[3])}


def generate(scenario, seed, out_dir, overrides=None, extra_meta=None):
    if scenario not in SCENARIOS:
        raise SystemExit(f"unknown scenario {scenario!r}, one of {sorted(SCENARIOS)}")
    params = merge(DEFAULTS, overrides)
    traj_rng, nav_rng, uwb_rng, init_rng = np.random.default_rng(seed).spawn(4)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    tr = truth(scenario, params, traj_rng)
    nav, nav_info = nav_samples(tr, params, nav_rng)
    uwb, uwb_info = uwb_samples(tr, params, uwb_rng)
    init = initial_state(tr, params, init_rng)

    ts = np.arange(0.0, params["duration"] + 1e-9, 1.0 / params["truth_out_hz"])
    truth_rows = np.column_stack([ts, at(tr, "p", ts), at(tr, "v", ts), at(tr, "a", ts),
                                  at(tr, "yaw", ts), at(tr, "yaw_rate", ts)])
    np.savetxt(out / "truth.csv", truth_rows, fmt="%.9g", delimiter=",", comments="",
               header="t,px,py,pz,vx,vy,vz,ax,ay,az,yaw,yaw_rate")
    np.savetxt(out / "nav.csv", nav, fmt="%.9g", delimiter=",", comments="",
               header="t,ax,ay,az,gx,gy,gz,mx,my,mz")
    np.savetxt(out / "uwb.csv", uwb, fmt=["%.9g", "%d", "%.9g"], delimiter=",", comments="",
               header="t,anchor,range")

    meta = {
        "generator_version": GENERATOR_VERSION,
        "scenario": scenario,
        "seed": seed,
        "duration": params["duration"],
        "anchors": params["anchors"],
        "init": init,
        "params": params,
        "drawn": {**nav_info, **uwb_info},
        "counts": {"nav": len(nav), "uwb": len(uwb)},
        **(extra_meta or {}),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    return meta


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    generate(sys.argv[1], int(sys.argv[2]), sys.argv[3])
