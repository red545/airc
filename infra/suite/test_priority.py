import datetime
import fcntl
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from priority import admit, contenders, deferred, progressed, night_hold
from run import build_lock, Preempted

class PriorityTest(unittest.TestCase):
    def test_real_kernel_waiter_is_seen_and_never_overtaken(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'lock'
            with path.open('a') as holder:
                fcntl.flock(holder,fcntl.LOCK_EX)
                peer=subprocess.Popen([sys.executable,'-c',
                    'import fcntl,sys; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX)',str(path)])
                try:
                    until=time.monotonic()+5
                    while not contenders(path) and time.monotonic()<until: time.sleep(.02)
                    self.assertIn(peer.pid,contenders(path))
                    with path.open('a') as suite:
                        with self.assertRaisesRegex(InterruptedError,'waiter'): admit(suite)
                    self.assertIsNone(peer.poll())
                finally:
                    fcntl.flock(holder,fcntl.LOCK_UN)
                    peer.wait(timeout=3)
            with path.open('a') as suite: admit(suite)

    def test_waiter_arrives_during_acquisition_releases_lock(self):
        with tempfile.TemporaryDirectory() as d:
            with (Path(d)/'lock').open('a') as lock:
                with patch('priority.contenders',side_effect=[[],[42]]):
                    with self.assertRaises(InterruptedError): admit(lock)
                with open(lock.name,'a') as peer: fcntl.flock(peer,fcntl.LOCK_EX|fcntl.LOCK_NB)

    def test_marker_appears_after_acquisition(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            with patch('run.blocked',side_effect=[False,True]):
                with self.assertRaises(Preempted):
                    with build_lock(root): self.fail('must not start')
            with (root/'.agent-build.lock').open('a') as peer:
                fcntl.flock(peer,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertTrue((root/'suite/low-priority.json').exists())

    def test_mac_descriptor_probe_excludes_self_but_counts_peers(self):
        import os
        with patch('priority.sys.platform','darwin'), patch('priority.subprocess.run',return_value=
                subprocess.CompletedProcess([],0,f'{os.getpid()}\n42\n','')):
            self.assertEqual(contenders(Path('/lock')),[42])

    def test_starvation_persists_across_retries_until_progress(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            start=datetime.datetime(2026,11,13,12,tzinfo=datetime.timezone.utc).timestamp()
            deferred(root,'peer',start); deferred(root,'peer again',start+5*3600)
            self.assertFalse(night_hold(root,start+5*3600))
            self.assertTrue(night_hold(root,start+6*3600))
            self.assertFalse(night_hold(root,start+12*3600)) # midnight UTC
            self.assertFalse(night_hold(root,start+17*3600)) # 05 UTC
            self.assertTrue(night_hold(root,start+18*3600))  # 06 UTC
            progressed(root)
            self.assertFalse(night_hold(root,start+19*3600))

if __name__=='__main__': unittest.main()
