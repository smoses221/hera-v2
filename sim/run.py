"""Run simulated experiments end to end: generate -> hera filter -> evaluate.

  python3 sim/run.py --scenario circle --seed 1                # offline
  python3 sim/run.py --scenario circle --seed 1 --mode live    # two hera nodes
  python3 sim/run.py --all                                     # every scenario, seeds 1-3
  python3 sim/run.py --all --mode both                         # + live, seed 1
  python3 sim/run.py --scenario static --set sigma_acc=0.3 --tag sa03

Each run goes to data/sim/<scenario>/s<seed>_<commit>[-dirty]_<mode>[_<tag>]/
with its inputs, outputs, metrics and plots. meta.json records the git
commit, `git describe --dirty`, and when the tree is dirty the sha256 of
`git diff HEAD` and the untracked files, so a run can be traced to its code;
erl_meta.json adds the md5 of every BEAM that ran.

Offline runs are deterministic: the same seed and code give a
byte-identical estimate.csv. Live runs replay the same seeded inputs in
real time through hera_measure -> hera_com (UDP multicast) -> hera_data on
two local Erlang nodes, so their output depends on timing.

--set key=value overrides hera_fusion's configuration (written to the run's
filter.json); value is JSON, e.g. --set planar=false --set q_jerk=10.
"""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
from glob import glob
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare  # noqa: E402
import evaluate  # noqa: E402
from generate import generate  # noqa: E402
from scenarios import SCENARIOS  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "data" / "sim"
LIVE_START_DELAY_S = 4.0   # time for both nodes to boot and connect
LIVE_EXTRA_TIMEOUT_S = 30.0


def git(*args):
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True,
                          check=True).stdout.strip()


def git_info():
    status = git("status", "--porcelain")
    info = {"commit": git("rev-parse", "HEAD"), "short": git("rev-parse", "--short", "HEAD"),
            "describe": git("describe", "--always", "--dirty"), "dirty": bool(status)}
    if status:
        diff = subprocess.run(["git", "diff", "HEAD", "--binary"], cwd=REPO,
                              capture_output=True, check=True).stdout
        info["diff_sha256"] = hashlib.sha256(diff).hexdigest()
        info["untracked"] = [line[3:] for line in status.splitlines() if line.startswith("??")]
    return info


def build():
    subprocess.run(["make", "-s", "-C", "c_src"], cwd=REPO, check=True)
    subprocess.run(["rebar3", "compile"], cwd=REPO, check=True, stdout=subprocess.DEVNULL)


def erl_cmd(*args):
    ebins = sorted(glob(str(REPO / "_build" / "default" / "lib" / "*" / "ebin")))
    return ["erl", "-noshell", "-pa", *ebins, *args]


def run_dir(out, scenario, seed, git_meta, mode, tag):
    name = f"s{seed}_{git_meta['short']}{'-dirty' if git_meta['dirty'] else ''}_{mode}"
    return Path(out) / scenario / (f"{name}_{tag}" if tag else name)


def prepare(directory, scenario, seed, git_meta, filter_set, tag):
    directory.mkdir(parents=True, exist_ok=True)
    for stale in directory.iterdir():  # a rerun replaces the previous one
        if stale.is_file():
            stale.unlink()
    generate(scenario, seed, directory, extra_meta={"git": git_meta, "tag": tag})
    if filter_set:
        (directory / "filter.json").write_text(json.dumps(filter_set, indent=2) + "\n")


def run_offline(directory):
    subprocess.run(erl_cmd("-run", "sim_replay", "main", str(directory)), cwd=REPO, check=True)


def run_live(directory):
    duration = json.loads((directory / "meta.json").read_text())["duration"]
    host = socket.gethostname().split(".")[0]
    suffix = f"{os.getpid()}"
    nodes = {"master": f"sim_master_{suffix}", "tag": f"sim_tag_{suffix}"}
    cookie = f"hera_sim_{suffix}"
    t0 = int((time.time() + LIVE_START_DELAY_S) * 1000)
    procs = {}
    for role, peer in [("master", "tag"), ("tag", "master")]:
        log = open(directory / f"live_{role}.log", "w")
        procs[role] = (subprocess.Popen(
            erl_cmd("-sname", nodes[role], "-setcookie", cookie, "-run", "sim_live", "main",
                    role, str(directory), str(t0), f"{nodes[peer]}@{host}"),
            cwd=REPO, stdout=log, stderr=subprocess.STDOUT), log)
    deadline = t0 / 1000 + duration + LIVE_EXTRA_TIMEOUT_S
    failed = []
    for role, (proc, log) in procs.items():
        try:
            proc.wait(timeout=max(deadline - time.time(), 1))
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        log.close()
        if proc.returncode != 0:
            failed.append(role)
    if failed:
        logs = "\n".join(f"--- live_{r}.log ---\n" + (directory / f"live_{r}.log").read_text()[-2000:]
                         for r in failed)
        raise RuntimeError(f"live run failed on {failed} (a hera_com that can't open its socket "
                           f"retries forever: is a non-loopback IPv4 interface up?)\n{logs}")


def parse_set(items):
    out = {}
    for item in items or []:
        key, _, value = item.partition("=")
        try:
            out[key] = json.loads(value)
        except json.JSONDecodeError:
            out[key] = value
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", nargs="+", choices=sorted(SCENARIOS))
    ap.add_argument("--seed", nargs="+", type=int, default=[1])
    ap.add_argument("--mode", choices=["offline", "live", "both"], default="offline")
    ap.add_argument("--all", action="store_true", help="every scenario, seeds 1 2 3 (live: seed 1 only)")
    ap.add_argument("--set", action="append", metavar="KEY=JSON", help="hera_fusion config override")
    ap.add_argument("--tag", help="suffix of the run directories (use it with --set)")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--no-plots", action="store_true")
    args = ap.parse_args()

    scenarios = sorted(SCENARIOS) if args.all else args.scenario
    if not scenarios:
        ap.error("give --scenario or --all")
    seeds = [1, 2, 3] if args.all else args.seed
    modes = ["offline", "live"] if args.mode == "both" else [args.mode]
    filter_set = parse_set(args.set)
    if filter_set and not args.tag:
        ap.error("--set needs --tag, so the runs don't overwrite the default ones")

    if not args.no_build:
        build()
    git_meta = git_info()
    if git_meta["dirty"]:
        print(f"note: working tree is dirty ({git_meta['describe']}), recorded in meta.json")

    jobs = [(sc, seed, mode) for mode in modes for sc in scenarios for seed in seeds
            if not (args.all and mode == "live" and seed != 1)]
    dirs = []
    for sc, seed, mode in jobs:
        d = run_dir(args.out, sc, seed, git_meta, mode, args.tag)
        prepare(d, sc, seed, git_meta, filter_set, args.tag)
        print(f"[{mode}] {sc} seed {seed} -> {d.relative_to(REPO) if d.is_relative_to(REPO) else d}",
              flush=True)
        (run_offline if mode == "offline" else run_live)(d)
        print("   ", evaluate.summary_line(evaluate.evaluate(d, plots=not args.no_plots)), flush=True)
        dirs.append(d)

    if len(dirs) > 1:
        summary = compare.compare(dirs, Path(args.out) / f"summary_{git_meta['describe']}"
                                  f"{'_' + args.tag if args.tag else ''}")
        print(f"summary: {summary}")


if __name__ == "__main__":
    main()
