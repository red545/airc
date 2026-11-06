#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Symbolize browser CDP native heap samples with the exact sampled app binary."""
import collections, json, pathlib, subprocess, sys
source, app = map(pathlib.Path, sys.argv[1:3])
p = json.loads(source.read_text())['profile']
module = next(m for m in p['modules'] if m['name'] == 'Airc Framework')
base = int(module['baseAddress'], 16)
addresses = sorted({a for s in p['samples'] for a in s['stack'] if base <= int(a,16) < base+module['size']})
address_file = source.with_suffix('.addresses'); address_file.write_text('\n'.join(addresses)+'\n')
fw = app/'Contents/Frameworks/Airc Framework.framework/Airc Framework'
lines = subprocess.check_output(['atos','-o',str(fw),'-l',module['baseAddress'],'-f',str(address_file)],text=True).splitlines()
names = dict(zip(addresses,lines)); totals = collections.Counter(); stacks=collections.Counter()
for s in p['samples']:
    stack = tuple(names.get(a,a) for a in s['stack'])
    stacks[stack] += s['total']
    for name in set(stack): totals[name] += s['total']
groups={}
for label, tokens in {'AI actor lists':['SafetyListManager::DoParseSafetyLists'], 'CRLSet':['ParseCRLSet'], 'ICU':['icu_','icu::'], 'V8':['v8::'], 'Resources':['ui::ResourceBundle::'], 'Lock telemetry':['LockMetricsRecorder::EnableRecording'], 'Observer registration':['WebContentsImpl::AddObserver']}.items():
    groups[label]=sum(sample['total'] for sample in p['samples'] if any(token in names.get(a,'') for a in sample['stack'] for token in tokens))
out={'groups':groups,'note':'Sampled live bytes, inclusive stacks overlap. Profiling overhead is not a baseline.',
     'inclusive':[{'bytes':n,'symbol':k} for k,n in totals.most_common()],
     'stacks':[{'bytes':n,'stack':k} for k,n in stacks.most_common(100)]}
source.with_suffix('.symbols.json').write_text(json.dumps(out,indent=2))
for k,n in totals.most_common(45): print(round(n/1e6,2),k)
