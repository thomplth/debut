#!/usr/bin/env python3
"""Plans the verification a change needs, from its paths and scripts/verify/manifest.json.

The plan is conservative: an unknown path, an unavailable base, shared runtime code, harness or
build plumbing, or a release each select full coverage. Every selection carries the path and
rule behind it, and every group left out is listed, so a narrowed plan can be audited.
"""

import argparse
import fnmatch
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "manifest.json")


def load_manifest():
    with open(MANIFEST) as handle:
        return json.load(handle)


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def parse_name_status(text):
    """Every path a change touches: both sides of a rename or copy, deletions included."""
    paths = []
    for line in text.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        paths.extend(field for field in fields[1:] if field)
    return paths


def changed_paths(base):
    """Committed, staged, unstaged and untracked changes relative to base."""
    committed = git("diff", "--name-status", "-M", f"{base}...HEAD")
    working = git("diff", "--name-status", "-M", "HEAD")
    staged = git("diff", "--name-status", "-M", "--cached", "HEAD")
    untracked = git("ls-files", "--others", "--exclude-standard")
    paths = parse_name_status(committed) + parse_name_status(working) + parse_name_status(staged)
    paths += [line for line in untracked.splitlines() if line]
    return sorted(set(paths))


def input_digest(base, paths):
    """Identifies exactly what was planned, so a stale plan can be refused."""
    digest = hashlib.sha256()
    digest.update(base.encode())
    for path in paths:
        digest.update(b"\0" + path.encode() + b"\0")
        if os.path.isfile(path):
            with open(path, "rb") as handle:
                digest.update(handle.read())
        else:
            digest.update(b"<absent>")
    return digest.hexdigest()


def match(manifest, path):
    for rule in manifest["rules"]:
        if fnmatch.fnmatchcase(path, rule["pattern"]):
            return rule
    return None


def plan(manifest, paths, release=False, full_reason=None):
    groups = set()
    full = False
    swift = False
    reasons = []
    if full_reason:
        full = True
        swift = True
        reasons.append(full_reason)
    if release:
        full = True
        swift = True
        reasons.append("release: full coverage on the exact candidate")
    for path in paths:
        rule = match(manifest, path)
        if rule is None:
            full = True
            swift = True
            reasons.append(f"{path}: unclassified path, so full coverage")
            continue
        swift = swift or rule["swift"]
        if rule["e2e"] == "full":
            full = True
            reasons.append(f"{path}: {rule['reason']} -> full")
        else:
            groups.update(rule["e2e"])
            label = ", ".join(sorted(rule["e2e"])) or "no VM groups"
            reasons.append(f"{path}: {rule['reason']} -> {label}")

    all_groups = manifest["groups"]
    if full:
        e2e = "full"
        profile = "full"
        not_selected = []
    else:
        e2e = sorted(groups)
        # Only window-moves runs the duration sweep; everything else omits it entirely.
        profile = "ordinary" if "window-moves" in groups else None
        not_selected = [group for group in all_groups if group not in groups]
    return {
        "e2e": e2e,
        "swiftTests": swift,
        "contracts": True,
        "durationProfile": profile,
        "notSelected": not_selected,
        "reasons": reasons,
        "paths": paths,
    }


def check_manifest(manifest):
    """Every source rule must select some behavioral verification."""
    problems = []
    known = set(manifest["groups"])
    for rule in manifest["rules"]:
        e2e = rule["e2e"]
        if e2e != "full":
            unknown = set(e2e) - known
            if unknown:
                problems.append(f"{rule['pattern']}: unknown groups {sorted(unknown)}")
        if rule["pattern"].startswith("Sources/") and e2e == [] and not rule["swift"]:
            problems.append(f"{rule['pattern']}: a source change that selects no tests")
    return problems


def render(result):
    lines = []
    e2e = result["e2e"]
    if e2e == "full":
        lines.append("E2E: full suite (duration profile: full)")
    elif e2e:
        profile = result["durationProfile"]
        suffix = f" (duration profile: {profile})" if profile else " (no duration sweep)"
        lines.append(f"E2E: {', '.join(e2e)}{suffix}")
    else:
        lines.append("E2E: none; no VM needed")
    lines.append(f"Swift tests: {'full serial suite' if result['swiftTests'] else 'not needed'}")
    lines.append("Shell contracts: all")
    if result["notSelected"]:
        lines.append(f"Not selected: {', '.join(result['notSelected'])}")
    lines.append("Because:")
    lines.extend(f"  {reason}" for reason in result["reasons"] or ["no changes"])
    lines.append(f"Input digest: {result['inputDigest'][:16]}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(prog="scripts/verify.sh plan")
    parser.add_argument("--base", help="verified base to plan from (default: merge-base with origin/main)")
    parser.add_argument("--changes", help="name-status file to plan instead of the checkout")
    parser.add_argument("--release", action="store_true", help="plan a release candidate")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    manifest = load_manifest()

    full_reason = None
    if args.changes:
        with open(args.changes) as handle:
            paths = sorted(set(parse_name_status(handle.read())))
        base = "changes-file"
    else:
        base = args.base
        if base is None:
            base = git("merge-base", "HEAD", "origin/main", check=False).strip()
        resolved = git("rev-parse", "--verify", "--quiet", f"{base}^{{commit}}", check=False).strip() if base else ""
        if not resolved:
            full_reason = f"base {base or '(none)'} is unavailable, so nothing can be narrowed"
            paths = []
        else:
            base = resolved
            paths = changed_paths(base)

    result = plan(manifest, paths, release=args.release, full_reason=full_reason)
    result["base"] = base
    result["inputDigest"] = input_digest(base, paths)
    print(json.dumps(result, indent=2) if args.json else render(result))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "check-manifest":
        issues = check_manifest(load_manifest())
        for issue in issues:
            print(issue, file=sys.stderr)
        sys.exit(1 if issues else 0)
    main()
