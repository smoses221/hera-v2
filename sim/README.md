# Simulated experiments

Seeded scenarios with a known ground truth, run through hera's Kalman filter (`hera_fusion`), then measured against that truth.

```
sim/generate.py ──> truth.csv  nav.csv  uwb.csv  meta.json
                         │
       offline: sim_replay (one Erlang process, true-time order, deterministic)
       live:    sim_live ×2 nodes: sim_measure → hera_measure → hera_com (UDP) → hera_data → sim_fusion
                         │
                    estimate.csv (+ received.csv, sent_*.csv when live)
                         │
sim/evaluate.py ──> metrics.json  trajectory.png  error_time.png  error_axes.png  error_cdf.png
sim/compare.py  ──> runs.csv  summary.md  rmse.png   (across runs)
```

Requirements: Erlang/OTP 27+ (for the `json` module) and rebar3, plus Python 3 with numpy and matplotlib. The default backend `mat` needs the host NIF, which `run.py` builds with `make -C c_src`.

## Running

```sh
python3 sim/run.py --scenario circle --seed 1                 # offline, about 1 s
python3 sim/run.py --scenario circle --seed 1 --mode live     # 2 hera nodes, real time (~65 s)
python3 sim/run.py --all --mode both                          # all scenarios, seeds 1-3 offline + live seed 1
python3 sim/run.py --scenario static --set sigma_acc=0.3 --tag sa03   # filter variant
make sim SCENARIO=rectangle SEED=2 MODE=offline
python3 sim/compare.py --out data/sim/summary_x data/sim/*/*  # compare any set of runs
```

Each run writes to `data/sim/<scenario>/s<seed>_<commit>[-dirty]_<mode>[_<tag>]/`. Running the same command again replaces that run.

## Setup simulated

- Two anchors: index 1 at (0, 0, 0) and index 2 at (4, 0, 0), as in `hera_uwb`'s default `anchors`. The tag stays at y > 0.
- One tag: the NAV board and the UWB board, treated as one rigid point. Roll and pitch are 0. The tag has a small vertical "bob" (~1 cm), except in `static`.
- Scenarios (60 s, all start at rest):

  | Scenario | Motion |
  |---|---|
  | `static` | still at (2, 2) |
  | `line` | back and forth between x = 1 and x = 3, yaw fixed at 0.5 rad |
  | `circle` | r = 1.2 m at 0.5 m/s, heading along the path |
  | `rectangle` | 2 m square, turning 90° in place at each corner, 2 laps |
  | `random_smooth` | seeded sum of slow sinusoids, wandering yaw |
- NAV, as `hera_nav` sends it: body frame, specific force including gravity, rad/s, µT. Sampled at 117.7 Hz (the rate fitted on the board), with white noise and a per-run residual bias (acc 0.02 m/s², gyro 0.001 rad/s).
- UWB, as `hera_uwb` sends it: anchors round-robin, one range every ~0.47 s (measured on the board), σ = 3 cm, 0.3 % dropouts. NLOS outliers are available but off.
- Filter start: the true start position plus noise (σ = 10 cm), velocity 0. The yaw starts from the truth plus noise (σ = 0.02 rad).

All the parameters are in `generate.py`'s `DEFAULTS` and copied into `meta.json`.

## Repeatability and traceability

- The seed fixes the trajectory, every noise draw and the filter's initial state. Each noise source has its own stream, spawned from the seed.
- Offline runs are deterministic: the same seed and code give a byte-identical `estimate.csv`.
- `meta.json → git` records the commit and `git describe --dirty`. If the tree is dirty, it also records the sha256 of `git diff HEAD` and the untracked files.
- `erl_meta.json` records the OTP version, the backend, the md5 of every BEAM that ran, and the filter's effective configuration.

## Metrics (`evaluate.py`)

The estimate is held from one update to the next and sampled at 100 Hz, which is what a consumer of the filter sees. Values marked *settled* exclude the first 5 s.

| Metric | Meaning |
|---|---|
| `pos2d`, `pos2d_settled` | horizontal error: RMSE, mean, median, p95, max, final |
| `x`, `y`, `z`, `vel2d`, `yaw` | per-component errors |
| `nees2d_mean`, `inside_3sigma` | consistency: mean NEES (≈ 2 if the covariance is honest) and the share of time inside the 3σ ellipse (≈ 98.9 %) |
| `uwb_only_pos2d*` | reference: two-circle fix from the latest range to each anchor |
| `live.<stream>` | live only: delivered/sent, timestamp error (receipt stamp − true time), send → processed delay; `seq_gaps` counts samples overwritten in `hera_data` before they were read |

## Live mode: what it does and doesn't test

Two local nodes run the real framework: `hera_measure`, `hera_com` multicast, and `hera_data`. The master gets its own NAV samples back through the multicast loopback, and the filter uses `hera_data`'s receipt timestamps. On one host the network takes about 1 ms and the clocks are shared, so live results stay close to offline. Board effects (Wi-Fi latency, SPI read time, clock offset between boards) are not simulated yet.

`hera_com` multicasts on the first non-loopback interface. Real boards on that network receive the sim's samples, and theirs reach the sim. `sim_fusion` uses only the two sim nodes and reports any others in `foreign_nodes`.
