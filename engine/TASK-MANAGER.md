# Task Manager startup sampling

The Task Manager's CPU sampler uses Chromium's private sequenced blocking runner.
BEST_EFFORT is fenced until startup completes: a visible page must become loaded
and idle (a busy page can wait a minute), or the three-minute failsafe must fire.
Memory and network refresh through other paths, which explains a blank CPU column.

Patch 034 changes only that runner to USER_VISIBLE. This is user-requested work:
Airc registers its sole observer when opening Task Manager and removes it on close.
Chromium starts providers/refresh with the first observer and stops them with the
last; constructing the runner alone does not schedule sampling. Pending samples
may finish after close, but there is no continuing closed-window sampling.

A constant trait is sufficient: changing priority dynamically would require a new
updatable runner, header/API changes and lifecycle hooks for no idle-work benefit.
The runner is private, so Airc's observer cannot configure it through a public API.
The patch also applies to any other Chromium task-manager consumers sharing this
runner; it does not reprioritize other thread-pool work.

Do not enable ImprovedStartupBestEffortDelay globally or signal startup complete
from the host to solve this: both release unrelated deferred work and change the
startup budget. No first-window-paint equivalence with Chrome is needed here.

Run `--script taskcpu` in a fresh Chromium app process with an isolated data directory.
It opens a loopback page with a 90 ms task every 120 ms, waits for load, opens the
real Task Manager and requires the busy renderer's first CPU within 3.5 seconds
(two samples plus model/display refresh). It checks visible-page preconditions,
continued fixture activity and sampler shutdown. Run it before other scenarios,
not after a quiet page has already completed startup. `AIRC_TMCPU_CLOSED=1` leaves
Task Manager closed for startup measurements. An external runner may supply
`AIRC_TMCPU_LAUNCH_EPOCH` so the scenario lives through the first 60 seconds.
