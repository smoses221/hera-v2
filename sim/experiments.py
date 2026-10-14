"""Experiments: one numbered folder per sim/run.py call, with notes.

  data/sim/NNN_<date>_<commit>[-dirty][_<tag>]/
    NOTES.md          free-form comments: edit it, or use `note` below
    experiment.json   command, commit, filter overrides, runs, status
    summary/          runs.csv, summary.md, rmse.png (sim/compare.py)
    <scenario>_s<seed>_<mode>/   one run each (sim/evaluate.py)

The number orders the folders by creation. NNN can be given as 3, 003
or the full folder name wherever an experiment is expected.

  python3 sim/experiments.py list                      # every experiment, with its first note
  python3 sim/experiments.py note 3 "q_jerk too low?"  # add a dated note to NOTES.md
  python3 sim/experiments.py show 3                    # print NOTES.md and the summary
"""

import argparse
import json
import re
import shlex
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = REPO / "data" / "sim"
NUMBERED = re.compile(r"^(\d{3,})_")
NOTES_HEADING = "## Notes"


def experiments(root=DEFAULT_ROOT):
    """Experiment folders, oldest first."""
    root = Path(root)
    found = [d for d in root.iterdir() if d.is_dir() and NUMBERED.match(d.name)] if root.exists() else []
    return sorted(found, key=lambda d: int(NUMBERED.match(d.name).group(1)))


def find(ref, root=DEFAULT_ROOT):
    """An experiment folder from its number (3, '003') or its name."""
    for d in experiments(root):
        if d.name == str(ref) or (str(ref).isdigit() and int(NUMBERED.match(d.name).group(1)) == int(ref)):
            return d
    raise SystemExit(f"no experiment {ref!r} in {root}")


def create(root, git_meta, tag=None, comment=None, info=None):
    """A new, numbered experiment folder with its experiment.json and NOTES.md."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    existing = experiments(root)
    number = int(NUMBERED.match(existing[-1].name).group(1)) + 1 if existing else 1
    now = datetime.now().astimezone()
    name = f"{number:03d}_{now:%Y-%m-%d}_{git_meta['describe']}" + (f"_{tag}" if tag else "")
    folder = root / name
    folder.mkdir()
    write_json(folder / "experiment.json", {
        "number": number, "name": name, "created": now.isoformat(timespec="seconds"),
        "command": shlex.join(["python3", *sys.argv]), "git": git_meta, "tag": tag,
        **(info or {}), "status": "running", "runs": []})
    lines = [f"# Experiment {number:03d}", "",
             f"- Created: {now:%Y-%m-%d %H:%M}",
             f"- Commit: {git_meta['describe']}",
             f"- Command: `{shlex.join(['python3', *sys.argv])}`",
             "", NOTES_HEADING, ""]
    if comment:
        lines.append(f"- {now:%Y-%m-%d %H:%M}: {comment}")
    (folder / "NOTES.md").write_text("\n".join(lines) + "\n")
    return folder


def update(folder, **fields):
    path = Path(folder) / "experiment.json"
    data = json.loads(path.read_text())
    data.update(fields)
    write_json(path, data)


def add_note(folder, text):
    path = Path(folder) / "NOTES.md"
    body = path.read_text() if path.exists() else f"# {Path(folder).name}\n\n{NOTES_HEADING}\n"
    if NOTES_HEADING not in body:
        body = body.rstrip("\n") + f"\n\n{NOTES_HEADING}\n"
    path.write_text(body.rstrip("\n") + f"\n- {datetime.now():%Y-%m-%d %H:%M}: {text}\n")


def notes(folder):
    """The note lines of NOTES.md (what follows the Notes heading)."""
    path = Path(folder) / "NOTES.md"
    if not path.exists():
        return []
    body = path.read_text().split(NOTES_HEADING, 1)
    return [line for line in (body[1] if len(body) > 1 else "").splitlines() if line.strip()]


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(DEFAULT_ROOT))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("note")
    p.add_argument("experiment")
    p.add_argument("text", nargs="+")
    p = sub.add_parser("show")
    p.add_argument("experiment")
    a = ap.parse_args()

    if a.cmd == "list":
        for d in experiments(a.root):
            meta = d / "experiment.json"
            info = json.loads(meta.read_text()) if meta.exists() else {}
            first = next(iter(notes(d)), "").lstrip("- ")
            print(f"{d.name:<45} {info.get('status', '?'):<8} {len(info.get('runs', [])):>3} runs  {first}")
    elif a.cmd == "note":
        d = find(a.experiment, a.root)
        add_note(d, " ".join(a.text))
        print(f"added to {d / 'NOTES.md'}")
    elif a.cmd == "show":
        d = find(a.experiment, a.root)
        print((d / "NOTES.md").read_text())
        summary = d / "summary" / "summary.md"
        if summary.exists():
            print(summary.read_text())


if __name__ == "__main__":
    main()
