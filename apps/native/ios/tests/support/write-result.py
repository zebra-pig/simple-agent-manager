"""Write run provenance, never infer a successful test from an artifact's presence."""
import datetime
import json
import os
import pathlib
import subprocess
import sys

output, status, started, *command = sys.argv[1:]
root = pathlib.Path(__file__).resolve().parents[5]

def read(argv):
    try:
        result = subprocess.run(argv, cwd=root, text=True, capture_output=True)
        return result.stdout.strip() if result.returncode == 0 else None
    except OSError:
        return None

revision = read(['git', 'rev-parse', 'HEAD'])
dirty = read(['git', 'status', '--porcelain', '--', 'apps/native'])
record = dict(command=command, exitCode=int(status), startedAt=started,
              finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              commit=os.environ.get('SAM_TEST_COMMIT') or revision or 'unknown',
              dirty=os.environ.get('SAM_TEST_DIRTY', str(bool(dirty)).lower()) if revision else os.environ.get('SAM_TEST_DIRTY', 'unknown'),
              xcode=read(['xcodebuild', '-version']))
pathlib.Path(output, 'test-run.json').write_text(json.dumps(record, indent=2) + '\n')
