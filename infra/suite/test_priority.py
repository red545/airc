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
    def test_real_kernel_waiter_is_seen_and_not_overtaken_within_patience(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'lock'
            with path.open('a') as holder:
                fcntl.flock(holder,fcntl.LOCK_EX)
                peer=subprocess.Popen([sys.executable,'-c',
                    'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(.5)',str(path)])
                try:
                    until=time.monotonic()+5
                    while not contenders(path) and time.monotonic()<until: time.sleep(.02)
                    self.assertIn(peer.pid,contenders(path))
                    with path.open('a') as suite:
                        with patch('priority.POLL',.05):
                            with self.assertRaisesRegex(InterruptedError,'not free'): admit(suite,patience=10,give_up=.3)
                    self.assertIsNone(peer.poll())
                finally:
                    fcntl.flock(holder,fcntl.LOCK_UN)
                # the queued peer goes first; the suite gets the lock after it, without aborting
                with path.open('a') as suite, patch('priority.POLL',.05):
                    admit(suite,patience=10,give_up=10)
                    self.assertEqual(peer.wait(timeout=3),0)

    def test_waits_in_place_and_ticks_instead_of_aborting(self):
        with tempfile.TemporaryDirectory() as d:
            with (Path(d)/'lock').open('a') as lock:
                ticks=[]; now=[0.0]
                with patch('priority.contenders',side_effect=[[42],[42],[],[]]):
                    waited=admit(lock,tick=lambda: ticks.append(1),patience=100,give_up=1000,
                                 clock=lambda: now[0],sleep=lambda s: now.__setitem__(0,now[0]+s))
                self.assertEqual(len(ticks),3); self.assertEqual(waited,4.0)

    def test_waiter_arrives_during_acquisition_goes_first(self):
        with tempfile.TemporaryDirectory() as d:
            with (Path(d)/'lock').open('a') as lock:
                now=[0.0]
                with patch('priority.contenders',side_effect=[[],[42],[],[]]):
                    admit(lock,patience=100,give_up=1000,clock=lambda: now[0],sleep=lambda s: now.__setitem__(0,now[0]+s))
                self.assertEqual(now[0],2.0)   # released once for the peer, then took it

    def test_starved_suite_takes_a_free_lock_despite_waiters(self):
        with tempfile.TemporaryDirectory() as d:
            with (Path(d)/'lock').open('a') as lock:
                now=[0.0]
                with patch('priority.contenders',return_value=[42]):
                    waited=admit(lock,patience=10,give_up=1000,clock=lambda: now[0],sleep=lambda s: now.__setitem__(0,now[0]+s))
                self.assertGreaterEqual(waited,10)

    def test_tick_can_stop_the_wait(self):
        with tempfile.TemporaryDirectory() as d:
            with (Path(d)/'lock').open('a') as lock, patch('priority.contenders',return_value=[42]):
                def tick(): raise InterruptedError('coordinator cancelled')
                with self.assertRaisesRegex(InterruptedError,'cancelled'): admit(lock,tick=tick)

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
