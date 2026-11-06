#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

"""Summarize completed Chromium trace slices by process/thread/task posting site."""
import collections,json,sys
trace=json.load(open(sys.argv[1])); names={}; totals=collections.defaultdict(lambda:[0,0])
for e in trace['traceEvents']:
    if e.get('name')=='thread_name':names[(e['pid'],e['tid'])]=e['args']['name']
for e in trace['traceEvents']:
    if e.get('ph')!='X':continue
    args=e.get('args',{}); site=args.get('src_func',args.get('function',args.get('src_file','')))
    if not site: site=str(args)[:180]
    k=(e['pid'],names.get((e['pid'],e['tid']),e['tid']),e['name'],site)
    totals[k][0]+=1;totals[k][1]+=e.get('dur',0)
for k,(n,d) in sorted(totals.items(),key=lambda r:-r[1][1])[:70]:print(n,round(d/1000,3),*k,sep='\t')
