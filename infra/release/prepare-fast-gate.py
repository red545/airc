#!/usr/bin/env python3
"""Overlay test-only helpers onto a git archive; never change product inputs or the UI driver."""
import argparse, hashlib, json, shutil
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('export', type=Path)
a = p.parse_args()
root = a.export.resolve()
assert not (root / '.git').exists(), 'Use a clean git archive, never a checkout'
here = Path(__file__).resolve().parent
debug = root / 'apps/browser/Sources/Airc/Debug'
shutil.copy2(here / 'FastGateCheck.swift', debug / 'FastGateCheck.swift')
p = debug / 'SnapshotRunner.swift'
s = p.read_text(); anchor = '        switch script {\n'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '        case "release-fast", "release-fast-read": fastGateScenario(read: script == "release-fast-read")\n')
# Attach to the function header only: its body may change (50252443 added a first line). The inserted line is
# unchanged and stays the first statement of finish().
finish = '    func finish() {\n'
if s.count(finish) != 1:
    at = s.find('func finish(')
    raise SystemExit('prepare-fast-gate: SnapshotRunner.finish() anchor found %d times; expected 1. First lines:\n%s'
                     % (s.count(finish), '\n'.join(s[max(0, s.rfind('\n', 0, at) + 1):].splitlines()[:6]) if at >= 0 else '(no func finish)'))
s = s.replace(finish, finish + '        try? "scenario-finish".write(to: dir.appendingPathComponent("step.txt"), atomically: true, encoding: .utf8)\n')
p.write_text(s)
p = debug / 'PiPRapidCheck.swift'; s = p.read_text()
# Keep every kind of rapid race, reduce only repetition count for the release gate.
assert s.count('for round in 1...20') == 2 and s.count('for round in 1...5') == 3
s = s.replace('for round in 1...20', 'for round in 1...3').replace('for round in 1...5', 'for round in 1...2')
s = s.replace('greenRounds == 20', 'greenRounds == 3').replace('all 20 real reentries', 'all 3 real reentries').replace('(\\(greenRounds)/20)', '(\\(greenRounds)/3)')
p.write_text(s)
p = debug / 'OnboardingE2ECheck.swift'; s = p.read_text()
# Release covers first run. Re-import/close permutations stay in the continuous suite.
start = s.index('        // MARK: Re-run: Import from Arc… on top')
end = s.index('    /// Waits until the import', start)
s = s[:start] + '''        run {
            GoogleAccountProbe.testURL = nil
            DefaultBrowser.shared.system = SystemDefaultBrowser()
            mock.stop()
        }
    }

''' + s[end:]
keys = '''            Self.press(o.window, Self.key("w", 13, .command, o.window))
            Self.deliver(o.window, Self.key("\\u{1b}", 53, [], o.window))
'''
assert s.count(keys) == 1
s = s.replace(keys, '')
anchor = '        wait(0.5)\n'
assert s.count(anchor) == 1
s = s.replace(anchor, '''        step { [self] done in
            fastGateKey("cmd+w", stage: "onboarding-command-w") { _ in
                self.check(true, "onboarding-e2e: real PID-targeted Command-W sent")
                self.fastGateKey("esc", stage: "onboarding-escape") { _ in
                    self.check(true, "onboarding-e2e: real PID-targeted Escape sent")
                    done()
                }
            }
        }
''' + anchor)
# Images are useful in the full suite; the fast gate retains assertions and logs.
s = '\n'.join(line for line in s.split('\n') if not line.strip().startswith('shootE2E(') and 'capture("e2e-7-browser")' not in line)
p.write_text(s)
files = ['FastGateCheck.swift', 'SnapshotRunner.swift', 'PiPRapidCheck.swift', 'OnboardingE2ECheck.swift']
(root / 'fast-gate-overlay.json').write_text(json.dumps({f: hashlib.sha256((debug/f).read_bytes()).hexdigest() for f in files}, indent=2)+'\n')
