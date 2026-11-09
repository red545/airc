# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""Conservative acceptance of perfgaps evidence, independent of nightly proxies."""
import math
import statistics


def number(x):
    return type(x) in (int, float) and math.isfinite(x)


def distribution(values):
    values = [v for v in values if number(v)]
    return ({'n': len(values), 'median': statistics.median(values), 'min': min(values), 'max': max(values)} if values else {})


def budgets(data):
    n, samples = data.get('requested_runs', 0), data.get('requested_samples', 0)
    runs = data.get('runs', {})
    def series(action):
        return runs.get(action, [])
    def complete(action):
        return n >= 3 and samples > 0 and len(series(action)) == n and (action != 'cbfirst' or all(r.get('command_bar_new_tab_tab_switches') == samples for r in series(action))) and all(r.get('guard') and min(g['hid_idle_s'] for g in r['guard']) >= 300 for r in series(action))
    def presented(action, key):
        return complete(action) and all(r.get('display_frames') and (r.get('refresh_hz') or 0) >= 119 and
            len(r.get(key, {}).get('presented_samples_ms', [])) == samples for r in series(action))
    def dist(action, key, first=False):
        return distribution([v[0] if first else statistics.median(v) for r in series(action) if (v := r.get(key, []))])
    def flatten(action, key):
        return [v for r in series(action) for v in r.get(key, [])]
    rows = []
    def row(key, metrics, passed, reason):
        rows.append({'id': key, 'status': 'unknown' if passed is None else 'pass' if passed else 'fail', 'measurements': metrics, 'reason': reason})
    swipe = series('swipe')
    measured = complete('swipe') and all((r.get('refresh_hz') or 0) >= 119 and r.get('swipe_120hz', {}).get('runs') == samples and r.get('swipe_120hz', {}).get('frames', 0) > 0 for r in swipe)
    drops = [r['swipe_120hz']['missed_vsyncs'] for r in swipe if r.get('swipe_120hz', {}).get('frames')]
    row('swipe', {'missed_120hz_vsyncs': distribution(drops)}, all(x == 0 for x in drops) if measured else None,
        'Pager.track; display-link timestamp gaps at 120 Hz. Callbacks are a presentation proxy, not GPU fence timestamps; requires 120 Hz display.')
    feedback = presented('feedback', 'feedback') and all(r.get('feedback_pressed') == samples for r in series('feedback'))
    f = [v for r in series('feedback') for v in r.get('feedback', {}).get('frames', [])]
    row('feedback', {'commit_ms': distribution([statistics.median(r['feedback']['commit_samples_ms']) for r in series('feedback') if r.get('feedback', {}).get('commit_samples_ms')]), 'ms': distribution([statistics.median(r['feedback']['presented_samples_ms']) for r in series('feedback') if r.get('feedback', {}).get('presented_samples_ms')])}, all(v == 1 for v in f) if feedback else None,
        'Native row mouseDown to first display callback after commit; press state verified.')
    hides, shows = flatten('sidebar', 'sidebar_hide_samples_ms'), flatten('sidebar', 'sidebar_show_samples_ms')
    valid = complete('sidebar') and len(hides) == n * samples and len(shows) == n * samples
    row('sidebar-toggle', {'hide_ms': dist('sidebar', 'sidebar_hide_samples_ms'), 'show_ms': dist('sidebar', 'sidebar_show_samples_ms')}, all(100 <= v <= 110 for v in hides + shows) if valid else None,
        'Toggle to sidebarFraction endpoint, 1 ms bounded observation; requires display callbacks; all samples must meet range.')
    first = [r.get('command_bar_new_tab', {}).get('presented_samples_ms', [])[:1] for r in series('cbfirst')]
    commits = [r.get('command_bar_new_tab', {}).get('commit_samples_ms', [])[:1] for r in series('cbfirst')]
    locals_ = flatten('cbkey', 'local_results')
    local_fail = complete('cbkey') and len(locals_) == n * samples and any(not v.get('tab_found') or not v.get('history_found') or (number(v.get('history_ms')) and v['history_ms'] > 1000 / 120) for v in locals_)
    sug = flatten('suggestions', 'suggestions_samples_ms')
    sug_valid = complete('suggestions') and len(sug) == n * samples and all(r.get('suggestions_loopback_requests', 0) >= samples for r in series('suggestions'))
    command = None
    if local_fail or (sug_valid and max(sug) > 100) or (presented('cbfirst', 'command_bar_new_tab') and any(v[0] > 8 for v in first)):
        command = False
    elif presented('cbfirst', 'command_bar_new_tab') and presented('cbkey', 'command_bar_key') and sug_valid and len(locals_) == n * samples and all(v.get('history_before_commit') for v in locals_):
        command = all(v == 1 for r in series('cbkey') for v in r['command_bar_key']['frames'])
    row('command', {'first_frame_ms': distribution([v[0] for v in first if v]), 'first_commit_ms': distribution([v[0] for v in commits if v]),
        'local_history_ms': distribution([statistics.median(values) for r in series('cbkey') if (values := [v['history_ms'] for v in r.get('local_results', []) if number(v.get('history_ms'))])]), 'local_history_all_samples_ms': distribution([v.get('history_ms') for v in locals_]), 'local_same_commit': sum(v.get('history_before_commit', False) for v in locals_),
        'local_samples': len(locals_), 'suggestions_ms': dist('suggestions', 'suggestions_samples_ms')}, command,
        'First opening per process; local tab + history rows by keystroke commit; suggestions include debounce, loopback HTTP and row application (1 ms polling). No WAN claim.')
    mem = [r.get('mem3', {}) for r in series('mem3')]
    required = ['timeout_unloaded', 'pressure_hook', 'pressure_unloaded', 'dirty_verified', 'audio_verified', 'title_retained', 'restored_title', 'icon_retained', 'icon_restored', 'lru_verified'] + [phase + '_protect_' + k for phase in ['timeout', 'pressure'] for k in ['shown', 'audio', 'dirty', 'chat', 'mail']]
    verdict = None
    if complete('mem3') and all(r.get('loaded') == 7 and r.get('dirty_verified') is True and r.get('audio_verified') is True for r in mem):
        verdict = all(all(r.get(k) is True for k in required) and number(r.get('initial_scroll')) and number(r.get('restored_scroll')) and abs(r['restored_scroll'] - r['initial_scroll']) <= 2 and r['initial_scroll'] > 0 for r in mem)
    if complete('mem3') and any(r.get('loaded') == 7 and r.get('restored_title') is True and number(r.get('initial_scroll')) and r['initial_scroll'] > 0 and number(r.get('restored_scroll')) and abs(r['restored_scroll'] - r['initial_scroll']) > 2 for r in mem):
        verdict = False
    row('MEM-3', {'timeout_ms': distribution([r.get('timeout_ms') for r in mem]), 'pressure_ms': distribution([r.get('pressure_ms') for r in mem]), 'initial_scroll': distribution([r.get('initial_scroll') for r in mem]), 'restored_scroll': distribution([r.get('restored_scroll') for r in mem]),
                  'failed_checks': sorted({k for r in mem for k in required if r.get(k) is not True} | ({'scroll_restoration'} if any(number(r.get('initial_scroll')) and number(r.get('restored_scroll')) and abs(r['initial_scroll'] - r['restored_scroll']) > 2 for r in mem) else set()))}, verdict,
        '2 s override; engine pressure hook; two eligible pages in LRU order; visible/audio/trusted dirty/pin/Favorite protections; title/icon/scroll restore. Synthetic Chromium workload.')
    cpu = [r.get('cpu_percent') for r in series('idle')]
    timer = [r.get('timers', {}).get('count') for r in series('idle')]
    valid = complete('idle') and all(number(v) for v in cpu)
    row('MEM-6', {'cpu_percent': distribution(cpu), 'main_runloop_timer_count': distribution(timer), 'timers_due_within_30s': distribution([r.get('timers', {}).get('due_within_30s') for r in series('idle')])},
        False if valid and (max(cpu) >= 1 or any(number(v) and v > 0 for v in timer)) else None,
        '30 s settled, 30 s all-process CPU; main CFRunLoop timer census includes framework timers. Dispatch/worker timers excluded: zero cannot prove global absence. No-media local pages, background window.')
    return rows
