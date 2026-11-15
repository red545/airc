"""An exclusively owned detached checkout; never reset or execute a shared tree."""
from pathlib import Path
import subprocess

OWNER = 'airc-background-suite-v1\n'


def prepare(repo, remote):
    repo = Path(repo).resolve()
    owner = repo / '.git' / 'airc-suite-owner'
    if not repo.exists():
        repo.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'clone', '--no-checkout', '--', remote, str(repo)], check=True)
        owner.write_text(OWNER)
    if not owner.is_file() or owner.read_text() != OWNER:
        raise RuntimeError('refusing non-owned checkout: ' + str(repo))
    git = ['git', '-C', str(repo)]
    actual = subprocess.check_output(git + ['remote', 'get-url', 'origin'], text=True).strip()
    if actual != remote:
        raise RuntimeError('owned checkout origin differs from configured remote')
    subprocess.run(git + ['fetch', 'origin'], check=True)
    rev = subprocess.check_output(git + ['rev-parse', 'origin/main^{commit}'], text=True).strip()
    # This checkout exists only for this serialized scheduler, never for agent edits.
    subprocess.run(git + ['checkout', '--detach', '--force', rev], check=True)
    subprocess.run(git + ['clean', '-ffd'], check=True)
    return rev


def command(repo, remote, args):
    """Fetch for EACH dry/full run, and execute that checkout's exact runner."""
    import sys
    rev = prepare(repo, remote)
    return [sys.executable, str(Path(repo) / 'infra/suite/run.py'),
            '--repo', str(repo), '--revision', rev, *args]
