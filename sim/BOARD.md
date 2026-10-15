# Running the live simulation on two boards

The same scenario as the offline and live modes, but on two GRiSP boards over Wi-Fi, through the real `hera_measure → hera_com (UDP multicast) → hera_data` path:

| Board | Runs | In place of |
|---|---|---|
| master (`--master`) | `sim_measure` replaying `nav.csv`, and `sim_fusion` (the filter) | `hera_nav` + the filter |
| tag (`--tag-board`) | `sim_measure` replaying `uwb.csv` | `hera_uwb` |

No sensor is read and no anchor is needed: the samples come from the generated scenario, so the result can be compared with the offline and live runs of the same seed.

## What runs where

`sim/run.py --mode board` generates the scenario on this host, then starts `sim_board` (an Erlang node on this host, hidden, cookie `grisp`). `sim_board` then:
1. **Connects to both boards** and checks them. It needs the same OTP release as this host, with `hera_data`, `hera_com` and `hera_measure_sup` running and **no `hera_measure` running**.
2. **Checks the simulation code.** The boards must run the same simulation modules as this host. With `--load-code`, this host's modules are loaded onto them instead. That lasts until the next reboot.
3. **Measures each board's clock offset** to this host, keeping the fastest of 20 round trips.
4. **Copies the run's files** to `/sim/<run>/` on each SD card, in 32 KB pieces.
5. **Starts both boards at the same instant T0**, converted to each board's own clock.
6. **Collects the results.** It waits for both boards' `done.json`, fetches the results, and deletes `/sim/<run>/` on the boards.

The run folder then also has `board_meta.json`: the nodes, their releases, the clock offsets and whether code was loaded. `evaluate.py` computes the same metrics as in live mode, under `"mode": "board"`.

## Steps

**1. Prepare the network and the boards**
- Turn on the hotspot (this laptop is `10.42.0.1`) and power the two boards.
- Check that they are reachable: `make info` (or `make info BOARDS="grisp-001316 grisp-001300"`).
- Reboot them, so no measure from an earlier session is running: `make reboot BOARDS="grisp-001316 grisp-001300"`. Wait until `make info` reaches them again.

**2. Start from a clean commit**, so the experiment is traceable (`git status` empty).

**3. Run one scenario, loading the code onto the boards**
```sh
make sim-board MASTER=grisp-001316 TAG_BOARD=grisp-001300 SCENARIO=circle LOAD_CODE=1 \
     COMMENT="first board run"
```
This is the same as `python3 sim/run.py --mode board --scenario circle --master grisp-001316 --tag-board grisp-001300 --load-code --comment "..."`. It takes about 75 s: 5 s to start, 60 s of scenario, then the fetch.

Without `LOAD_CODE=1`, the boards must already run the same simulation code, i.e. a release built from this commit (`make release`). Either way, `erl_meta.json` records the md5s of the modules that ran on the master.

**4. Look at the result**
```sh
make sim-list
python3 sim/experiments.py show <N>
```
Open `data/sim/<N>_…/circle_s1_board/`, then:
- `metrics.json → live`: delivered/sent per stream, `seq_gaps` (samples overwritten in `hera_data` before they were read), timestamp error, and send → processed delay.
- `metrics.json → board.clock`: the clock offsets and their uncertainty (`max_error_ms`).
- `drift.png`, `error_time.png`: as for the other modes.

**5. Compare with the same seed offline and live**
```sh
python3 sim/run.py --scenario circle --mode both --comment "reference for board run <N>"
python3 sim/compare.py data/sim/<N>_*/*_s1_* data/sim/<M>_*/*_s1_*
```

## Reading the timing numbers

- **Timestamp error:** `hera_data`'s receipt time minus the sample's true time, both as seconds since T0. It includes the one-way delay (tag → master for UWB; the master's own multicast loopback for NAV) and any wait before the sample was processed. It also includes the error of the two clock offsets, at most `max_error_ms` each (half a round trip over Wi-Fi). Crystal drift adds about 1–3 ms over 60 s.
- **`seq_gaps`:** the filter polls `hera_data` every 1 ms. If the board's timer is coarser than that, or the master is overloaded, NAV samples (118 Hz) get overwritten and show up here. That is a real baseline flaw, not a simulation artefact.
- **`late`:** samples older than the filter's time, applied with dt = 0. This happens when UWB arrives after newer NAV samples.

## If something goes wrong

| Message | Fix |
|---|---|
| `cannot reach board@grisp-…` | The board is off, the hostname is wrong, or this laptop isn't on the hotspot. Check `make info`. |
| `runs OTP …, this host …` | `--load-code` needs the same OTP release. Deploy a release built from this commit instead (`make release`). |
| `hera_measure(s) running` | Reboot the board (`make reboot BOARDS=…`). |
| `the boards' code differs` | Add `LOAD_CODE=1`, or deploy this commit. |
| `matrix backend mat doesn't work` | The release lacks the numerl NIF. Rebuild and deploy. |
| `no …/done.json before the timeout` | A board crashed or rebooted (`on_crash = reboot`). Look at its serial console. The files stay in `/sim/` on the SD card until the next successful run of the same name. |
| `a board failed` + a stack trace | It shows the error from that board. Its files stay in `/sim/<run>/`. |

Interrupting a run (Ctrl-C) leaves the boards' processes running until the scenario ends. A reboot clears them.
