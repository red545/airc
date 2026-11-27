# infra/tools

- `priority-build.py`: the one shared way to read, join and hand on `status/priority-build`
  (the build-priority marker beside the repo). Use it for every join and hand-on; never edit the
  marker by hand. `python3 infra/tools/priority-build.py --help` lists the subcommands
  (`status`, `join`, `handon`, `leave`, `is-head`, `may-build`). Writes are atomic (flock on
  `status/.priority-build.lock`, temp file + rename); the head is the first word of the first
  line, so decorations like "(handed on by …)" don't matter, and a second `handon` by the same
  agent is refused (exit 3) instead of skipping the next agent.
- Tests: `python3 infra/tools/test_priority_build.py`.
