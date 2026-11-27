#!/usr/bin/env python3
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Tests for priority-build.py. Run: python3 -m unittest -v test_priority_build (from this folder),
or python3 test_priority_build.py. Every case works on a temp copy, never the live marker."""
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, 'priority-build.py')
spec = importlib.util.spec_from_file_location('priority_build', TOOL)
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)

NOW = '2026-11-27T03:00:00Z'

# Marker shapes seen in status/priority-build, queue.md and agents' scripts (26-27 Nov and earlier).
LIVE_0249 = ('tailreds\n'
             'Handed on by smallgaps2 at 2026-11-27T02:33:14Z (smallgaps2 build step done)\n'
             'next: agentparkcpu, launchtails-quiet, windowleak\n')
PERF14_STYLE = 'smallgaps2 (handed on by launchtails)\nnext: agentparallel, windowleak\n'
RELEASE072_JOIN = 'release072\nrelease072 0.1.60 test/public build (joined 2026-11-24T10:01:02.123456+00:00)\n'
RELEASE072_HANDOFF = ('agentmainview\nHanded on by release072 at 2026-11-24T10:20:00.5+00:00\n'
                      'next: release072, nosteplimit\n')
HISTSUGG_STYLE = 'driverclickmods\natomic handoff from histsugg\n'


def parse(t):
    return pb.Marker.parse(t)


class ParseTests(unittest.TestCase):
    def test_live_marker(self):
        m = parse(LIVE_0249)
        self.assertEqual(m.head, 'tailreds')
        self.assertEqual(m.queue, ['agentparkcpu', 'launchtails-quiet', 'windowleak'])
        self.assertTrue(m.handed.startswith('Handed on by smallgaps2 at 2026-11-27T02:33:14Z'))
        self.assertEqual(m.render(), LIVE_0249)  # already normal: round-trips byte for byte

    def test_decorated_head_is_first_word(self):
        # 27 Nov 02:17-02:33: smallgaps2's exact-line match missed this and held the marker 15 min.
        m = parse(PERF14_STYLE)
        self.assertEqual(m.head, 'smallgaps2')
        self.assertEqual(m.queue, ['agentparallel', 'windowleak'])

    def test_name_inside_decoration_is_not_head(self):
        # 26 Nov 23:31: launchtails' grep -w matched "launchtails" inside the decoration.
        self.assertNotEqual(parse(PERF14_STYLE).head, 'launchtails')

    def test_release072_head_with_words(self):
        m = parse(RELEASE072_JOIN)
        self.assertEqual(m.head, 'release072')
        self.assertEqual(m.queue, [])
        self.assertEqual(m.notes, ['release072 0.1.60 test/public build (joined 2026-11-24T10:01:02.123456+00:00)'])

    def test_markdown_and_punctuation_head(self):
        self.assertEqual(parse('**smallgaps2**: build 3\n').head, 'smallgaps2')
        self.assertEqual(parse('`tailreds`\n').head, 'tailreds')
        self.assertEqual(parse('\n\n  tailreds  \n').head, 'tailreds')

    def test_next_variants(self):
        m = parse('a\nnext: b (rejoin), c,d  e -> f, then g, b, a\nNext: h\n')
        self.assertEqual(m.head, 'a')
        self.assertEqual(m.queue, ['b', 'c', 'd', 'e', 'f', 'g', 'h'])  # dupes and head dropped

    def test_hyphenated_and_dotted_names(self):
        m = parse('launchtails-quiet\nnext: release0.1.64, p20c_b\n')
        self.assertEqual(m.head, 'launchtails-quiet')
        self.assertEqual(m.queue, ['release0.1.64', 'p20c_b'])

    def test_absent_and_empty(self):
        self.assertFalse(parse(None).exists)
        e = parse('')
        self.assertTrue(e.exists)
        self.assertIsNone(e.head)

    def test_only_next_line_promotes_first(self):
        m = parse('next: a, b\n')
        self.assertEqual((m.head, m.queue), ('a', ['b']))
        self.assertTrue(m.warnings)

    def test_handed_line_first(self):
        m = parse('Handed on by x at 2026-11-27T01:00:00Z\ny\nnext: z\n')
        self.assertEqual((m.head, m.queue), ('y', ['z']))

    def test_normalize_decorated(self):
        self.assertEqual(parse(PERF14_STYLE).render(),
                         'smallgaps2\nsmallgaps2 (handed on by launchtails)\nnext: agentparallel, windowleak\n')
        # Normalizing twice gives the same text (no duplicated note).
        once = parse(PERF14_STYLE).render()
        self.assertEqual(parse(once).render(), once)


class TransitionTests(unittest.TestCase):
    def test_join_absent_becomes_head(self):
        m, msg = pb.do_join(parse(None), 'smallgaps2')
        self.assertEqual(m.render(), 'smallgaps2\n')

    def test_join_appends_and_is_idempotent(self):
        m, _ = pb.do_join(parse(LIVE_0249), 'newagent')
        self.assertEqual(m.queue[-1], 'newagent')
        m2, msg = pb.do_join(m, 'newagent')
        self.assertIs(m2, m)
        self.assertIn('already', msg)
        m3, _ = pb.do_join(m, 'tailreds')  # head joining again: no-op
        self.assertIs(m3, m)

    def test_join_keeps_handed_line_and_notes(self):
        m, _ = pb.do_join(parse(LIVE_0249), 'x')
        self.assertEqual(m.render(), LIVE_0249.replace('windowleak\n', 'windowleak, x\n'))

    def test_join_front(self):
        m, _ = pb.do_join(parse(LIVE_0249), 'release075', front=True)
        self.assertEqual(m.queue, ['release075', 'agentparkcpu', 'launchtails-quiet', 'windowleak'])
        m, _ = pb.do_join(parse(LIVE_0249), 'windowleak', front=True)  # moves, doesn't duplicate
        self.assertEqual(m.queue, ['windowleak', 'agentparkcpu', 'launchtails-quiet'])
        self.assertEqual(m.head, 'tailreds')  # --front never displaces the head

    def test_front_rules(self):
        pb.check_front('release075')
        pb.check_front('chromium114')
        with self.assertRaises(pb.Refused):
            pb.check_front('smallgaps2')
        pb.check_front('smallgaps2', force=True)

    def test_handon_to_next(self):
        m, _ = pb.do_handon(parse(LIVE_0249), 'tailreds', reason='build step done', now=NOW)
        self.assertEqual(m.render(), 'agentparkcpu\nHanded on by tailreds at %s (build step done)\n'
                                     'next: launchtails-quiet, windowleak\n' % NOW)

    def test_handon_decorated_head(self):
        # The smallgaps2 failure: decorated head line must still be handed on by smallgaps2.
        m, _ = pb.do_handon(parse(PERF14_STYLE), 'smallgaps2', now=NOW)
        self.assertEqual(m.render(), 'agentparallel\nHanded on by smallgaps2 at %s\nnext: windowleak\n' % NOW)

    def test_double_handon_is_refused(self):
        # The launchtails failure: build-end hand-on, then the EXIT trap's second hand-on.
        text = 'launchtails\nnext: smallgaps2, agentparallel, windowleak\n'
        m, _ = pb.do_handon(parse(text), 'launchtails', now=NOW)
        self.assertEqual(m.head, 'smallgaps2')
        again = parse(m.render())
        with self.assertRaises(pb.Refused):
            pb.do_handon(again, 'launchtails', now=NOW)
        self.assertEqual(again.head, 'smallgaps2')

    def test_handon_by_queued_agent_refused(self):
        with self.assertRaises(pb.Refused):
            pb.do_handon(parse(LIVE_0249), 'windowleak')

    def test_handon_last_removes(self):
        # winclose's bash bug skipped the mv when no next: was left; here the marker goes.
        m, msg = pb.do_handon(parse('winclose\n'), 'winclose')
        self.assertIsNone(m.render())
        self.assertIn('removed', msg)
        m, _ = pb.do_handon(parse('winclose\nnext: winclose\n'), 'winclose')  # self in next: too
        self.assertIsNone(m.render())

    def test_handon_drops_old_notes(self):
        m, _ = pb.do_handon(parse(HISTSUGG_STYLE + 'next: ytads\n'), 'driverclickmods', now=NOW)
        self.assertEqual(m.render(), 'ytads\nHanded on by driverclickmods at %s\n' % NOW)

    def test_handon_rejoin(self):
        m, _ = pb.do_handon(parse(RELEASE072_HANDOFF.replace('agentmainview', 'release072', 1)
                                  .replace('next: release072, ', 'next: agentmainview, ')),
                            'release072', rejoin=True, front=True, now=NOW)
        self.assertEqual((m.head, m.queue), ('agentmainview', ['release072', 'nosteplimit']))
        m, _ = pb.do_handon(parse(LIVE_0249), 'tailreds', rejoin=True, now=NOW)
        self.assertEqual(m.queue, ['launchtails-quiet', 'windowleak', 'tailreds'])

    def test_leave(self):
        m, _ = pb.do_leave(parse(LIVE_0249), 'launchtails-quiet')
        self.assertEqual(m.queue, ['agentparkcpu', 'windowleak'])
        self.assertTrue(m.handed)  # unrelated lines kept
        m2, msg = pb.do_leave(m, 'nobody')
        self.assertIs(m2, m)
        m3, _ = pb.do_leave(parse(LIVE_0249), 'tailreds', now=NOW)  # head leaving = hand on
        self.assertEqual(m3.head, 'agentparkcpu')

    def test_bad_names(self):
        for bad in ('', 'a b', '-x', 'a,b', 'x\n'):
            with self.assertRaises(ValueError):
                pb.check_name(bad)


class CliTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='priotool-test-')
        self.marker = os.path.join(self.dir, 'priority-build')

    def tearDown(self):
        for f in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, f))
        os.rmdir(self.dir)

    def write(self, text):
        with open(self.marker, 'w') as f:
            f.write(text)

    def read(self):
        return pb.read_text(self.marker)

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = pb.main(['--marker', self.marker] + list(args))
        return rc, out.getvalue(), err.getvalue()

    def test_is_head_and_may_build(self):
        self.assertEqual(self.run_main('is-head', 'x')[0], 1)
        self.assertEqual(self.run_main('may-build', 'x')[0], 0)
        self.write(PERF14_STYLE)
        self.assertEqual(self.run_main('is-head', 'smallgaps2')[0], 0)
        self.assertEqual(self.run_main('is-head', 'launchtails')[0], 1)
        self.assertEqual(self.run_main('may-build', 'launchtails')[0], 1)
        self.assertEqual(self.run_main('is-head', 'agentparallel')[0], 1)

    def test_dry_run_leaves_file(self):
        self.write(LIVE_0249)
        rc, out, _ = self.run_main('--dry-run', 'handon', 'tailreds')
        self.assertEqual(rc, 0)
        self.assertIn('agentparkcpu\nHanded on by tailreds at', out)
        self.assertEqual(self.read(), LIVE_0249)

    def test_full_chain_and_exit_codes(self):
        self.write(LIVE_0249)
        self.assertEqual(self.run_main('join', 'smallgaps2')[0], 0)
        self.assertEqual(self.run_main('join', 'smallgaps2', '--front')[0], 3)  # not a release agent
        self.assertEqual(self.run_main('join', 'release075', '--front')[0], 0)
        self.assertEqual(pb.Marker.parse(self.read()).queue,
                         ['release075', 'agentparkcpu', 'launchtails-quiet', 'windowleak', 'smallgaps2'])
        self.assertEqual(self.run_main('handon', 'windowleak')[0], 3)
        self.assertEqual(self.run_main('handon', 'tailreds', '--reason', 'build step done')[0], 0)
        self.assertEqual(self.run_main('handon', 'tailreds')[0], 3)  # EXIT trap's second call
        self.assertEqual(pb.Marker.parse(self.read()).head, 'release075')
        for who in ('release075', 'agentparkcpu', 'launchtails-quiet', 'windowleak'):
            self.assertEqual(self.run_main('handon', who)[0], 0)
        self.assertEqual(pb.Marker.parse(self.read()).head, 'smallgaps2')
        self.assertEqual(self.run_main('leave', 'smallgaps2')[0], 0)
        self.assertIsNone(self.read())
        self.assertEqual(self.run_main('handon', 'smallgaps2')[0], 3)
        self.assertEqual(self.run_main('join', 'bad name')[0], 2)
        self.assertEqual(self.run_main('handon', 'x', '--front')[0], 2)
        # no tmp files left behind; only the lock file
        self.assertEqual(sorted(os.listdir(self.dir)), ['.priority-build.lock'])

    def test_noop_does_not_rewrite(self):
        self.write(PERF14_STYLE)
        st = os.stat(self.marker).st_mtime_ns
        self.run_main('join', 'agentparallel')
        self.run_main('leave', 'nobody')
        self.assertEqual(self.read(), PERF14_STYLE)
        self.assertEqual(os.stat(self.marker).st_mtime_ns, st)

    def test_status(self):
        self.write(LIVE_0249)
        rc, out, _ = self.run_main('status')
        self.assertIn('head:  tailreds', out)
        self.assertIn('queue: agentparkcpu, launchtails-quiet, windowleak', out)
        rc, out, _ = self.run_main('status', '--json')
        self.assertIn('"head": "tailreds"', out)
        os.unlink(self.marker)
        self.assertIn('no marker', self.run_main('status')[1])

    def test_lock_timeout(self):
        self.write('a\n')
        with pb.Lock(self.marker, 5):
            rc, _, err = self.run_main('--lock-timeout', '0', 'join', 'b')
        self.assertEqual(rc, 4)
        self.assertEqual(self.read(), 'a\n')

    def test_hand_edit_race_retries(self):
        # A hand-written script rewrites the marker between our read and our write.
        self.write('a\nnext: b\n')
        real = pb.read_text
        calls = {'n': 0}

        def racing(path):
            calls['n'] += 1
            if calls['n'] == 2:  # the re-check right before the write
                with open(path, 'w') as f:
                    f.write('a\nnext: b, c\n')
            return real(path)
        pb.read_text = racing
        try:
            self.run_main('join', 'd')
        finally:
            pb.read_text = real
        self.assertEqual(pb.Marker.parse(self.read()).queue, ['b', 'c', 'd'])

    def test_default_marker_discovery(self):
        # status/ beside a tools folder or two levels above a repo's infra/tools/
        os.makedirs(os.path.join(self.dir, 'status'))
        open(os.path.join(self.dir, 'status', '.agent-build.lock'), 'w').close()
        old_file, old_env = pb.__file__, os.environ.pop('AIRC_PRIORITY_BUILD', None)
        try:
            for sub in ('tools', os.path.join('airc', 'infra', 'tools')):
                pb.__file__ = os.path.join(self.dir, sub, 'priority-build.py')
                self.assertEqual(pb.default_marker(), os.path.join(self.dir, 'status', 'priority-build'))
            os.environ['AIRC_PRIORITY_BUILD'] = '/tmp/airc-test/pb'
            self.assertEqual(pb.default_marker(), '/tmp/airc-test/pb')
        finally:
            pb.__file__ = old_file
            os.environ.pop('AIRC_PRIORITY_BUILD', None)
            if old_env is not None:
                os.environ['AIRC_PRIORITY_BUILD'] = old_env
            os.unlink(os.path.join(self.dir, 'status', '.agent-build.lock'))
            os.rmdir(os.path.join(self.dir, 'status'))

    def test_parallel_joins_via_subprocess(self):
        self.write('head\n')
        procs = [subprocess.Popen([sys.executable, TOOL, '--marker', self.marker, 'join', 'a%02d' % i],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(20)]
        self.assertEqual([p.wait() for p in procs], [0] * 20)
        self.assertEqual(sorted(pb.Marker.parse(self.read()).queue), ['a%02d' % i for i in range(20)])


if __name__ == '__main__':
    unittest.main(verbosity=2)
