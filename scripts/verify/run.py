#!/usr/bin/env python3
"""Runs the verification a plan selects: contracts, the serial Swift suite, then Tart groups.

Two rules keep the expensive part honest. A plan is refused if its inputs change before the VM
run, since it would verify something other than what was planned. And an E2E run on unchanged
inputs is not repeated just to get a green result: a failed assertion needs a changed input or a
stated reason, and an infrastructure (setup) failure gets one recovery retry, then stops so the
prerequisite gets repaired. Every attempt, its result, evidence and reason is recorded.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
STATE = os.environ.get("DEBUT_VERIFY_STATE", os.path.expanduser("~/Library/Caches/Debut/Verify"))


def plan(args):
    command = [sys.executable, os.path.join(HERE, "plan.py"), "--json"]
    if args.full:
        command.append("--release")
    if args.base:
        command += ["--base", args.base]
    return json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)


def stage(title, command):
    print(f"\n== {title}: {' '.join(shlex.quote(part) for part in command)}", flush=True)
    started = time.monotonic()
    status = subprocess.call(command)
    print(f"== {title}: {'passed' if status == 0 else f'failed ({status})'} in {time.monotonic() - started:.1f}s",
          flush=True)
    return status


def tart_command(selection):
    tart = os.environ.get("DEBUT_VERIFY_TART", os.path.join(REPO, "scripts", "tart-e2e.sh"))
    if selection["e2e"] == "full":
        return [tart, "run", "--duration-profile", "full"]
    command = [tart, "run", "--groups", ",".join(selection["e2e"]),
               "--duration-profile", selection["durationProfile"] or "ordinary"]
    if "rendering" not in selection["e2e"]:
        command.append("--no-gallery")
    return command


def attempts():
    path = os.path.join(STATE, "attempts.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]


def record(entry):
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "attempts.jsonl"), "a") as handle:
        handle.write(json.dumps(entry) + "\n")


def retry_decision(key, reason):
    """None to proceed, or the message explaining why this attempt is refused."""
    history = [entry for entry in attempts() if entry["key"] == key and entry["result"] != "canceled"]
    if not history or reason:
        return None, False
    last = history[-1]
    evidence = last.get("evidence") or "(no evidence directory recorded)"
    if last["result"] == "failed":
        return (f"The last E2E run on exactly these inputs failed its checks; evidence: {evidence}\n"
                "Rerunning unchanged inputs will not change that. Change an input or add a diagnostic, "
                "or pass --retry-reason \"...\" to record why another run is justified."), False
    trailing = 0
    for entry in reversed(history):
        if entry["result"] != "setup_failure":
            break
        trailing += 1
    if trailing >= 2:
        return (f"Two setup failures on unchanged inputs; the last evidence: {evidence}\n"
                "Repair the prerequisite (VM, permissions, build) instead of retrying, "
                "or pass --retry-reason \"...\" once it is repaired."), False
    return None, trailing == 1


def run_tart(command):
    print(f"\n== E2E: {' '.join(shlex.quote(part) for part in command)}", flush=True)
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    evidence = None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        stripped = line.strip()
        if stripped.startswith("evidence: "):
            evidence = stripped[len("evidence: "):]
    status = process.wait()
    result = "passed" if status == 0 else "failed"
    if evidence and os.path.exists(os.path.join(evidence, "report.json")):
        with open(os.path.join(evidence, "report.json")) as handle:
            result = json.load(handle).get("result", result)
    print(f"== E2E: {result} in {time.monotonic() - started:.1f}s", flush=True)
    return status, result, evidence


def main():
    parser = argparse.ArgumentParser(prog="scripts/verify.sh affected|full")
    parser.add_argument("mode", choices=["affected", "full"])
    parser.add_argument("--base")
    parser.add_argument("--retry-reason", default="")
    args = parser.parse_args()
    args.full = args.mode == "full"

    selection = plan(args)
    print(f"Plan ({args.mode}): E2E {selection['e2e'] if selection['e2e'] == 'full' else ', '.join(selection['e2e']) or 'none'}; "
          f"Swift tests {'yes' if selection['swiftTests'] else 'no'}; contracts yes")
    for reason in selection["reasons"]:
        print(f"  {reason}")

    contracts = os.environ.get("DEBUT_VERIFY_CONTRACTS")
    contracts_command = [contracts] if contracts else [
        "/bin/bash", "-c", 'for test in Tests/CI/*.sh; do bash "$test" || exit 1; done']
    if stage("Contracts", contracts_command) != 0:
        return 1

    if selection["swiftTests"]:
        swift = os.environ.get("DEBUT_VERIFY_SWIFT_TEST")
        swift_command = [swift] if swift else [
            "/usr/bin/env", "TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault", "/usr/bin/swift"]
        if stage("Swift tests", swift_command + ["test", "--no-parallel"]) != 0:
            return 1

    if selection["e2e"] == []:
        print("\nNo E2E groups selected; no VM needed.")
        return 0

    # The VM run must verify the inputs that were planned, not whatever the tree holds now.
    current = plan(args)
    if current["inputDigest"] != selection["inputDigest"]:
        print("\nInputs changed since planning, so this plan no longer describes the tree. "
              "Run scripts/verify.sh again.", file=sys.stderr)
        return 3

    command = tart_command(selection)
    key = f'{selection["inputDigest"]}|{" ".join(command[1:])}'
    refusal, recovery = retry_decision(key, args.retry_reason)
    if refusal:
        print("\n" + refusal, file=sys.stderr)
        return 4
    if recovery:
        print("\nThis is the one recovery retry for an unchanged setup failure.")
    if args.retry_reason:
        print(f"\nAnother attempt on these inputs, because: {args.retry_reason}")

    status, result, evidence = run_tart(command)
    record({
        "key": key, "result": result, "evidence": evidence, "reason": args.retry_reason,
        "recoveryRetry": recovery, "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
    })
    return status


if __name__ == "__main__":
    sys.exit(main())
