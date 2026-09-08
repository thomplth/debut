#!/usr/bin/env python3
"""Plan exclusively from tags. Annotated tags record the monotonic bundle build."""
import argparse
import datetime
import os
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('bump', choices=['patch', 'minor', 'major', 'nightly'])
parser.add_argument('--require-changes', action='store_true')
args = parser.parse_args()

def git(*command):
    return subprocess.check_output(['git', *command], text=True).strip()

# Immutable migration facts: these numeric tags were automated prereleases before
# nightly suffixes existed. GitHub prerelease flags are mutable and cannot be the
# source of truth for version planning. Never delete or reuse these tags.
legacy_prereleases = {'v0.1.1', 'v0.1.2', 'v0.2.1', 'v0.2.2', 'v0.3.1', 'v0.3.2',
                      'v0.4.1', 'v0.4.2', 'v0.4.3'}
pattern = re.compile(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-nightly\.[0-9]{8}(?:\.[1-9][0-9]*)?)?$')
tags = git('tag', '--list').splitlines()
versions = {tag: pattern.fullmatch(tag) for tag in tags}
versions = {tag: match for tag, match in versions.items() if match}
stable = [tag for tag, match in versions.items() if not match[4] and tag not in legacy_prereleases]
previous_stable = max(stable, key=lambda t: tuple(map(int, versions[t].group(1, 2, 3))), default='')
major, minor, patch = map(int, versions[previous_stable].group(1, 2, 3)) if previous_stable else (0, 1, 0)
if args.bump == 'nightly':
    if previous_stable:
        minor += 1
    patch = 0
    date = os.environ.get('RELEASE_DATE', datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d'))
    datetime.datetime.strptime(date, '%Y%m%d')
    version = f'{major}.{minor}.{patch}-nightly.{date}'
    base, counter = version, 2
    while 'v' + version in tags:
        version = f'{base}.{counter}'
        counter += 1
else:
    if previous_stable:
        if args.bump == 'major': major, minor, patch = major + 1, 0, 0
        elif args.bump == 'minor': minor, patch = minor + 1, 0
        else: patch += 1
    occupied = [int(m[3]) for m in versions.values() if not m[4] and (int(m[1]), int(m[2])) == (major, minor)]
    if occupied:
        patch = max(patch, max(occupied) + 1)
    version = f'{major}.{minor}.{patch}'
    while 'v' + version in tags:
        patch += 1
        version = f'{major}.{minor}.{patch}'

# Find the last released commit on this history, independent of semantic ordering.
# A newer stable release also suppresses an identical nightly. Stable notes always
# start from the previous stable, never from an intervening nightly.
commits = {}
maximum_build = 9999  # Greater than every pre-migration 0.x bundle version.
compatible_nightly_tags = set()
for tag in versions:
    commit = git('rev-parse', tag + '^{commit}')
    commits.setdefault(commit, []).append(tag)
    annotation = git('for-each-ref', '--format=%(contents)', 'refs/tags/' + tag)
    for build in re.findall(r'^Debut-build: ([1-9][0-9]*)$', annotation, re.MULTILINE):
        maximum_build = max(maximum_build, int(build))
    if versions[tag][4] and re.search(r'^Debut-update-channel: nightly-v1$', annotation, re.MULTILINE):
        compatible_nightly_tags.add(tag)
previous_release = ''
history = git('rev-list', '--first-parent', 'HEAD').splitlines()
for commit in history:
    if commit in commits:
        previous_release = sorted(commits[commit])[0]
        break
previous_update_tag = previous_stable if args.bump != 'nightly' else ''
if args.bump == 'nightly':
    for commit in history:
        candidates = compatible_nightly_tags.intersection(commits.get(commit, []))
        if candidates:
            previous_update_tag = sorted(candidates)[-1]
            break
should_release = not (args.require_changes and previous_release and
                      not git('rev-list', previous_release + '..HEAD'))
print('previous_tag=' + (previous_release if args.bump == 'nightly' else previous_stable))
print('previous_stable_tag=' + previous_stable)
print('previous_update_tag=' + previous_update_tag)
print('version=' + version)
print('tag=v' + version)
print('channel=' + ('nightly' if args.bump == 'nightly' else 'stable'))
print('build_version=' + str(maximum_build + 1))
print('should_release=' + str(should_release).lower())
