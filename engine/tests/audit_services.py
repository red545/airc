#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Source inventory, not a runtime allocation profiler. Run on the pinned mirror."""
import json, pathlib, re, sys
root=pathlib.Path(sys.argv[1]); result=[]
for path in sorted((root/'chrome/browser').rglob('*.cc')):
    text=path.read_text(errors='replace')
    for match in re.finditer(r'(\w+)::\s*ServiceIsCreatedWithBrowserContext\(\)\s*const\s*\{',text):
        start=match.end(); depth=1; end=start
        while depth and end<len(text):
            depth += (text[end]=='{')-(text[end]=='}'); end+=1
        body=text[start:end-1].strip()
        result.append({'factory':match[1], 'path':str(path.relative_to(root)),
                       'line':text[:match.start()].count('\n')+1,
                       'policy':body, 'upstream_lazy_gate':'kLazyKeyedServiceInstantiation' in body})
print(json.dumps({'note':'Source declarations include platform/feature-gated factories; dependencies can instantiate additional services. Not a claim all are live on macOS.', 'factories':result},indent=2))
