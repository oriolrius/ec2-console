#!/usr/bin/env python3
"""Validate the DBAI phase-profile catalog (PROFILE-01, doc-18 §5).

Rejects missing versions, unresolved placeholder tokens, and an exam/practical
profile that resolves through a mutable reference. `null` means "explicitly
pending" and is allowed for candidate profiles (but never for a qualified ref).

Usage:
  validate-profiles.py [catalog.yaml]     # default: sibling catalog.yaml
  validate-profiles.py --selftest
"""
from __future__ import annotations
import argparse, re, sys
from pathlib import Path
import yaml

HERE = Path(__file__).resolve().parent
SCHEMA = "dbai/profile-catalog/v1"
REQUIRED_PHASES = {"S2", "S3", "S4", "S7", "S8", "S13", "S14"}  # boundaries named
PLACEHOLDERS = {"tbd", "todo", "pending", "xxx", "changeme", "n/a", "?"}
MUTABLE = {"latest", "main", "master", "head"}
VERSION_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]*[0-9](-candidate)?$", re.I)


def _bad_token(v) -> str | None:
    """Return a reason if a scalar is a placeholder/mutable token, else None.
    None/null values are allowed (explicitly pending)."""
    if v is None:
        return None
    s = str(v).strip().lower()
    if s in PLACEHOLDERS:
        return f"placeholder token {v!r}"
    if s in MUTABLE:
        return f"mutable reference {v!r}"
    return None


def validate(cat: dict) -> list[str]:
    errs: list[str] = []
    if not isinstance(cat, dict):
        return ["catalog is not a mapping"]
    if cat.get("schema") != SCHEMA:
        errs.append(f"schema must be {SCHEMA!r}")
    profiles = cat.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        return errs + ["profiles must be a non-empty list"]

    named_phases = set()
    versions = set()
    for i, p in enumerate(profiles):
        tag = f"profiles[{i}]"
        if not isinstance(p, dict):
            errs.append(f"{tag}: not a mapping"); continue
        name = p.get("name"); tag = f"profile {name!r}" if name else tag
        if not name:
            errs.append(f"{tag}: missing name")

        ver = p.get("version")
        if not ver:
            errs.append(f"{tag}: missing version")
        elif _bad_token(ver) or not VERSION_RE.match(str(ver)):
            errs.append(f"{tag}: invalid/mutable version {ver!r}")
        else:
            versions.add(str(ver))

        if p.get("status") not in ("candidate", "qualified"):
            errs.append(f"{tag}: status must be candidate|qualified")
        if not p.get("instance_size"):
            errs.append(f"{tag}: missing instance_size")
        for ph in p.get("phases", []) or []:
            named_phases.add(ph)

        is_exam = p.get("kind") == "practical" or "exam" in str(name)
        # scan every scalar pin for placeholder/mutable tokens
        for key, val in p.items():
            if isinstance(val, dict):
                for tk, tv in val.items():
                    r = _bad_token(tv)
                    if r:
                        errs.append(f"{tag}: {key}.{tk} has {r}")
            elif isinstance(val, list):
                for tv in val:
                    r = _bad_token(tv)
                    if r:
                        errs.append(f"{tag}: {key} entry has {r}")
            else:
                r = _bad_token(val)
                if r:
                    # a mutable ref is always fatal; exam makes it especially so
                    where = "exam profile " if is_exam and "mutable" in r else ""
                    errs.append(f"{tag}: {where}{key} has {r}")
        # qualified profiles may not carry any null (pending) pin
        if p.get("status") == "qualified":
            for key, val in p.items():
                if val is None:
                    errs.append(f"{tag}: qualified profile has unset field {key!r}")

    # profile boundaries must be named (AC#1)
    missing = REQUIRED_PHASES - named_phases
    if missing:
        errs.append(f"catalog does not name required phase boundaries: {sorted(missing)}")

    # selections must reference known versions
    for p in profiles:
        for sel in (p.get("selects") or []):
            if sel not in versions:
                errs.append(f"profile {p.get('name')!r}: selects unknown version {sel!r}")
    return errs


def selftest() -> int:
    ok = True
    live = yaml.safe_load((HERE / "catalog.yaml").read_text())
    errs = validate(live)
    ok &= not errs
    print(f"[{'OK' if not errs else 'WRONG'}] live catalog.yaml: "
          f"{'valid' if not errs else str(len(errs)) + ' errors'}")
    for e in errs:
        print(f"        - {e}")

    base = {"schema": SCHEMA, "profiles": [
        {"name": "foundations", "version": "foundations-0.1.0", "status": "candidate",
         "phases": ["S2", "S3"], "instance_size": "t3.small"},
        {"name": "containers", "version": "containers-0.1.0", "status": "candidate",
         "phases": ["S4", "S7"], "instance_size": "t3.medium"},
        {"name": "operations", "version": "operations-0.1.0", "status": "candidate",
         "phases": ["S8", "S13"], "instance_size": "t3.large"},
        {"name": "exam-s14-practical", "version": "exam-s14-practical-0.1.0",
         "status": "candidate", "kind": "practical", "phases": ["S14"],
         "instance_size": "t3.large"},
    ]}
    import copy
    cases = []
    c = copy.deepcopy(base); del c["profiles"][0]["version"]
    cases.append(("missing version", c))
    c = copy.deepcopy(base); c["profiles"][0]["ami"] = "TBD"
    cases.append(("placeholder pin", c))
    c = copy.deepcopy(base); c["profiles"][3]["ami"] = "latest"
    cases.append(("exam via mutable latest", c))
    for label, cat in cases:
        errs = validate(cat)
        good = bool(errs)
        ok &= good
        print(f"[{'OK' if good else 'WRONG'}] reject {label}: "
              f"{'rejected' if errs else 'ACCEPTED (wrong)'}")
    print("SELFTEST: PASS" if ok else "SELFTEST: FAIL")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("catalog", nargs="?", default=str(HERE / "catalog.yaml"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    errs = validate(yaml.safe_load(Path(args.catalog).read_text()))
    if errs:
        print(f"FAIL: {len(errs)} error(s)")
        for e in errs:
            print(f"  - {e}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
