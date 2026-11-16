"""Run macOS XCTest directly when no GUI testmanagerd service is available."""
import json
import pathlib
import re
import subprocess
import sys

output = pathlib.Path(sys.argv[1])
bundle = output / 'build/Build/Products/Debug/NativeBehaviorTests.xctest'
result = subprocess.run(['xcrun', 'xctest', str(bundle)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(output / 'xctest.log').write_text(result.stdout)
print(result.stdout)
counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures?', result.stdout)
if result.returncode or not counts or int(counts[-1][0]) < 1 or int(counts[-1][1]):
    raise SystemExit(result.returncode or 1)
(output / 'summary.json').write_text(json.dumps(dict(runner='xcrun xctest', totalTests=int(counts[-1][0]), failedTests=int(counts[-1][1])), indent=2) + '\n')
