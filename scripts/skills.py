#!/usr/bin/env python3
"""Skill inventory from frontmatter. No dependencies beyond the stdlib.

  skills.py list [--group G] [--tag T] [--status S] [--paths]
  skills.py groups
  skills.py readme          # rewrite the Skills table in README.md
  skills.py check           # name==dir, prefix==group, required metadata
"""
import re, sys, argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"
ARCHIVE = "_archive"

def frontmatter(p: Path) -> dict:
    text = p.read_text()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    fm, cur, out = m.group(1), None, {}
    for line in fm.splitlines():
        if re.match(r"^\S", line):
            k, _, v = line.partition(":")
            v = v.strip()
            if v == "":
                cur = k.strip(); out[cur] = {}
            else:
                cur = None; out[k.strip()] = v.strip('"')
        elif cur and line.strip():
            k, _, v = line.strip().partition(":")
            v = re.sub(r'\s+#.*$', "", v).strip().strip('"')
            if v.startswith("["):
                v = [x.strip().strip('"') for x in v.strip("[]").split(",") if x.strip()]
            out[cur][k.strip()] = v
    return out

def skills(include_archive=False):
    for p in sorted(SKILLS.glob("*/*/SKILL.md")):
        group = p.parent.parent.name
        if group == ARCHIVE and not include_archive:
            continue
        fm = frontmatter(p)
        meta = fm.get("metadata", {}) if isinstance(fm.get("metadata"), dict) else {}
        yield dict(
            name=fm.get("name", "?"), dir=p.parent, group=group,
            description=fm.get("description", ""),
            status=meta.get("status", "live"),
            tags=[t.strip() for t in str(meta.get("tags", "")).split(",") if t.strip()],
            verified=meta.get("last-verified", ""),
        )

def cmd_list(a):
    rows = [s for s in skills(a.status == "dormant")
            if (not a.group or s["group"] == a.group)
            and (not a.tag or a.tag in s["tags"])
            and (not a.status or s["status"] == a.status)]
    for s in rows:
        if a.paths:
            print(s["dir"])
        else:
            print(f'{s["name"]:<36} {s["group"]:<10} {s["status"]:<9} {",".join(s["tags"])}')

def cmd_groups(a):
    for g in sorted({s["group"] for s in skills()}):
        print(g)

def cmd_readme(a):
    lines = ["| Skill | Group | Status | Tags | What it does |", "|---|---|---|---|---|"]
    for s in skills():
        desc = s["description"].split(". ")[0].rstrip(".")
        lines.append(f'| `{s["name"]}` | {s["group"]} | {s["status"]} | {", ".join(s["tags"])} | {desc} |')
    table = "\n".join(lines)
    readme = ROOT / "README.md"
    text = readme.read_text()
    new = re.sub(r"<!-- skills-table -->.*?<!-- /skills-table -->",
                 lambda m: "<!-- skills-table -->\n" + table + "\n<!-- /skills-table -->", text, flags=re.S)
    if new == text and "<!-- skills-table -->" not in text:
        sys.exit("README.md has no <!-- skills-table --> markers")
    readme.write_text(new)
    print(f"README.md: {len(lines)-2} skills")

def cmd_check(a):
    bad = 0
    for s in skills(include_archive=True):
        d = s["dir"].name
        if s["name"] != d:
            print(f'name/dir mismatch: {s["name"]} in {d}'); bad += 1
        if s["group"] not in ("meta", ARCHIVE) and not d.startswith(s["group"] + "-"):
            print(f'{d}: name should start with "{s["group"]}-"'); bad += 1
        if not s["tags"]:
            print(f"{d}: no metadata.tags"); bad += 1
        if s["status"] not in ("live", "skeleton", "dormant"):
            print(f'{d}: bad status {s["status"]}'); bad += 1
        if s["status"] == "live" and not re.match(r"\d{4}-\d{2}-\d{2}", s["verified"]):
            print(f"{d}: live but no metadata.last-verified date"); bad += 1
    print("ok" if not bad else f"{bad} problem(s)")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    l = sub.add_parser("list"); l.add_argument("--group"); l.add_argument("--tag"); l.add_argument("--status"); l.add_argument("--paths", action="store_true")
    sub.add_parser("groups"); sub.add_parser("readme"); sub.add_parser("check")
    a = ap.parse_args()
    {"list": cmd_list, "groups": cmd_groups, "readme": cmd_readme, "check": cmd_check}[a.cmd](a)
