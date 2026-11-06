# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class TraceTests(unittest.TestCase):
    def test_raw_signposts_references_and_duplicate_tables(self):
        begin = '<row><event-time>10</event-time><process id="1" fmt="Airc (42)"/><event-type>Begin</event-type><os-signpost-identifier>2</os-signpost-identifier><signpost-name>frame</signpost-name></row>'
        end = '<row><event-time>20</event-time><process ref="1"/><event-type>End</event-type><os-signpost-identifier>2</os-signpost-identifier><signpost-name>frame</signpost-name></row>'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'signposts.xml').write_text('<root>' + (begin + end) * 2 + '</root>')
            (p / 'samples.xml').write_text('<root>' + ''.join(
                '<row><sample-time>%d</sample-time><thread fmt="Main Thread"/><tagged-backtrace><frame name="draw"/></tagged-backtrace></row>' % t
                for t in (5, 15, 25)) + '</root>')
            result = subprocess.check_output([sys.executable, str(Path(__file__).with_name('tpsum.py')),
                                              str(p / 'samples.xml'), '--name', 'frame', '--intervals',
                                              str(p / 'signposts.xml')], text=True)
            self.assertIn('intervals 1,', result)
            self.assertIn('selected (focus None): 1', result)
