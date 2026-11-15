"""Shared read-only background suite panel; never contacts either Mac."""
import html
import json
from pathlib import Path


def panel(status):
    suite = Path(status) / 'suite'
    def read(name):
        try:
            return json.loads((suite / name).read_text())
        except (OSError, ValueError):
            return {}
    latest = read('latest.json')
    scheduler = read('scheduler.json')
    green = read('last-green.json').get('revision', 'none')
    candidate = read('qualified.json').get('revision', 'none')
    e = lambda x: html.escape(str(x))
    critical = latest.get('critical', [])
    warning = '<strong style="color:#e5484d">CRASH / HANG / NO PID: ' + e(', '.join(critical)) + '</strong>' if critical else ''
    rows = ''.join(f'<li>{e(engine)}: {e(c.get("PASS", 0))} pass / {e(c.get("FAIL", 0))} fail / {e(c.get("ENV", 0))} environment</li>'
                   for engine, c in latest.get('counts', {}).items())
    progress = f'<p>{e(latest["resume_label"])} (pinned revision above)</p>' if latest.get('resume_label') else ''
    if latest.get('state') == 'running':
        progress += f'<p>Current step: {e(latest.get("current_step", "starting"))}'
        progress += f' · Waiting on: {e(latest["waiting_on"])}' if latest.get('waiting_on') else ' · Executing'
        progress += '</p>'
    if scheduler.get('state') == 'waiting':
        progress += f'<p>Scheduler waiting on: {e(", ".join(scheduler.get("waiting_on", [])))}</p>'
    elif scheduler.get('state') == 'retrying':
        progress += f'<p>Scheduler retry in {e(scheduler.get("retry_after_seconds", 60))} seconds</p>'
    quits = latest.get('shutdown_warnings', [])
    if quits:
        entries = ''.join(f'<li>{e(q["case"])}: {e(q["severity"])} · {e(q["message"])} · '
                          f'1-minute load {e(q.get("load_1m"))} / {e(q.get("cores"))} cores'
                          f'{e(" · " + q["reason"]) if q.get("reason") else ""}</li>' for q in quits)
        progress += (f'<details><summary>Slow-quit observations: {len(quits)}; severe quits: '
                     f'{e(latest.get("severe_quit_occurrences", 0))}</summary><ul>{entries}</ul></details>')
    return (f'<section>{warning}<h2>Background full suite</h2><p>Last green rev: {e(green)}<br>'
            f'Qualified candidate: {e(candidate)}<br>Latest: {e(latest.get("revision", "none"))} · '
            f'{e(latest.get("state", "waiting"))}</p>{progress}<ul>{rows}</ul><p>New reds since previous run: '
            f'{e(", ".join(latest.get("new_reds", [])) or "none")}</p></section>')
