# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('proof',ROOT/'scripts/release/fast_gate_proof.py')
proof=importlib.util.module_from_spec(spec);spec.loader.exec_module(proof)

class FastGateProofTests(unittest.TestCase):
    def test_rejects_incomplete_stale_crashed_or_over_budget_receipts(self):
        config_path=ROOT/'infra/release/fast-gate.json'
        config=json.loads(config_path.read_text())
        good=dict(schema=1,state='PASS',revision='a'*40,seconds=210,crash_reports=[],driver_unchanged=True,
                  config_sha256=hashlib.sha256(config_path.read_bytes()).hexdigest(),
                  cases=[dict(engine=e,script=c['script'],state='PASS',seconds=10,pids=[123],exit_statuses={'123':0},cleanup={})
                         for e in config['engines'] for c in config['cases'] if e in c.get('engines',config['engines'])])
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'proof.json'
            path.write_text(json.dumps(good));proof.verify(path,'a'*40)
            bad=[]
            for k,v in [('state','FAIL'),('seconds',601),('seconds',float('nan')),('crash_reports',['Airc.ips']),
                        ('driver_unchanged',False),('revision','b'*40),('config_sha256','stale')]:
                row=copy.deepcopy(good);row[k]=v;bad.append(row)
            row=copy.deepcopy(good);row['cases'].pop();bad.append(row)
            for k,v in [('pids',[]),('state','SKIP'),('cleanup',{'killed':[123]}),('seconds',150),
                        ('exit_statuses',{}),('exit_statuses',{'123':15})]:
                row=copy.deepcopy(good);row['cases'][0][k]=v;bad.append(row)
            for i,row in enumerate(bad):
                with self.subTest(i=i):
                    path.write_text(json.dumps(row))
                    with self.assertRaises(ValueError):proof.verify(path,'a'*40)

if __name__=='__main__':unittest.main()
