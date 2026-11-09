#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Where a probed launch's late frames spent their time (frameprobe.py --probe output).

python3 infra/perf/frameprobe_report.py DIR [--top 25] [--stacks]

DIR is one launch's output (it holds snap/probe-*.txt, snap/probe-marks.json and result.json). For each measured
action (Command Bar opening, New Space) it prints the turn's phases (work, the run loop's observers before Core
Animation, CA's layout/display and its commit) and the functions the main thread was in during each phase, by
inclusive and self samples. For animations (swipe, sidebar) it does the same for every late frame: the samples between
the two display-link callbacks around the gap. Sample counts times the interval are approximate times.
"""
import argparse
import collections
import json
from pathlib import Path
import re


def load(d):
    snap = d / 'snap'
    syms = {}
    if (snap / 'probe-symbols.txt').exists():
        for line in (snap / 'probe-symbols.txt').read_text().splitlines():
            if line.startswith('#') or ' ' not in line:
                continue
            pc, name = line.split(' ', 1)
            syms[pc] = clean(name)
    for line in (snap / 'probe-pcs.txt').read_text().splitlines():
        parts = line.split(' ', 3)
        if parts[0] not in syms or syms[parts[0]].startswith('0x'):
            syms[parts[0]] = (Path(parts[1]).name + '`' + parts[3]) if len(parts) == 4 else parts[0]
    samples = []
    for line in (snap / 'probe-samples.txt').read_text().splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        samples.append((float(f[0]), int(f[1]), [syms.get(pc, pc) for pc in f[2:]]))
    marks = json.loads((snap / 'probe-marks.json').read_text())
    result = json.loads((d / 'result.json').read_text()) if (d / 'result.json').exists() else {}
    return samples, marks, result


def clean(name):
    name = re.sub(r' \(in ([^)]+)\)', r' [\1]', name)
    name = re.sub(r' \([^()]*\.swift:\d+\)$', '', name)
    name = re.sub(r' \+ \d+$', '', name)
    return name.strip()


def summarize(samples, top, show_stacks, indent='    '):
    if not samples:
        print(indent + '(no samples)')
        return
    incl, selfc, stacks = collections.Counter(), collections.Counter(), collections.Counter()
    for _, _, frames in samples:
        if not frames:
            continue
        selfc[frames[0]] += 1
        for f in set(frames):
            incl[f] += 1
        stacks[' < '.join(frames[:14])] += 1
    n = len(samples)
    print(indent + f'{n} samples; inclusive:')
    for f, c in incl.most_common(top):
        print(indent + f'  {c:5d} {100 * c / n:5.1f}%  {f[:150]}')
    print(indent + 'self:')
    for f, c in selfc.most_common(top // 2):
        print(indent + f'  {c:5d} {100 * c / n:5.1f}%  {f[:150]}')
    if show_stacks:
        print(indent + 'stacks:')
        for s, c in stacks.most_common(12):
            print(indent + f'  {c:4d}  {s[:900]}')


PHASES = [('work', 't0_ms', 'work_end'), ('rest of the turn before CA', 'work_end', 'bw_before_ca'),
          ('CA before layout', 'bw_before_ca', 'ca_pre_layout'), ('CA layout + display', 'ca_pre_layout', 'ca_pre_commit'),
          ('CA commit', 'ca_pre_commit', 'ca_post_commit'), ('after the commit', 'ca_post_commit', 'bw_after_ca')]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('dir', type=Path)
    p.add_argument('--top', type=int, default=25)
    p.add_argument('--stacks', action='store_true')
    p.add_argument('--only', help='labels starting with this')
    o = p.parse_args()
    samples, probe, result = load(o.dir)
    interval = probe.get('interval_us', 250) / 1000
    print(f'{o.dir}: {len(samples)} samples every {interval} ms (full {probe.get("full")})')
    for m in probe['marks']:
        label = m.get('label', '')
        if o.only and not label.startswith(o.only):
            continue
        if 't0_ms' in m:
            k = dict(m['marks'], t0_ms=m['t0_ms'])
            print(f"\n== {label}: commit {m['commit_ms']:.2f} ms (work {m['work_ms']:.2f}), presented {m['presented_ms']:.2f}, "
                  f"frames {m['frames']} {m.get('environment') or ''}")
            print('   ' + ', '.join(f'{name} {k[b] - k[a]:.2f}' for name, a, b in PHASES if a in k and b in k))
            for name, a, b in PHASES:
                if a in k and b in k:
                    inside = [s for s in samples if k[a] <= s[0] < k[b]]
                    print(f'  -- {name} ({k[b] - k[a]:.2f} ms)')
                    summarize(inside, o.top, o.stacks)
        elif 'ticks_ms' in m or 'release_vsync_ms' in m:
            ticks = m.get('ticks_ms')
            if ticks is None:
                continue
            gaps = [(a, b) for a, b in zip(ticks, ticks[1:]) if b - a > 1.5 * 8.333]
            print(f"\n== {label}: {len(ticks)} ticks, {len(gaps)} late")
            for a, b in gaps:
                print(f'  -- late frame at +{(a - ticks[0]) / 8.333:.0f} frames, gap {b - a:.2f} ms')
                summarize([s for s in samples if a <= s[0] < b], o.top, o.stacks)
    # Swipes: ticks from result.json (swipe_timestamps_s), release from the marks.
    releases = [m for m in probe['marks'] if 'release_vsync_ms' in m]
    for i, ticks_s in enumerate(result.get('swipe_timestamps_s', [])):
        ticks = [t * 1000 for t in ticks_s]
        label = f'swipe {i}'
        if o.only and not label.startswith(o.only):
            continue
        rel = next((m['release_vsync_ms'] for m in releases if m['label'] == label), None)
        end = ticks[0] + 700
        ticks = [t for t in ticks if t <= end]
        gaps = [(a, b) for a, b in zip(ticks, ticks[1:]) if b - a > 1.5 * 8.333]
        print(f"\n== {label}: release at +{(rel - ticks[0]) / 8.333:.0f} frames" if rel else f"\n== {label}", f'{len(gaps)} late')
        for a, b in gaps:
            since = f'+{(a - rel) / 8.333:.0f} frames after release' if rel else ''
            print(f'  -- late frame {since}, gap {b - a:.2f} ms')
            summarize([s for s in samples if a <= s[0] < b], o.top, o.stacks)


if __name__ == '__main__':
    main()
