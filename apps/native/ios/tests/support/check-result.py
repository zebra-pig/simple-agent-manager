"""Reject empty or all-skipped XCTest runs, as well as reported test failures."""
import json
import pathlib
import subprocess
import sys

bundle = pathlib.Path(sys.argv[1])
summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)]))
bundle.with_name('summary.json').write_text(json.dumps(summary, indent=2) + '\n')
if summary.get('failedTests', 0) or summary.get('passedTests', 0) < 1 or summary.get('result') != 'Passed':
    raise SystemExit('XCTest did not report a nonempty passing suite: ' + json.dumps(summary))
print(f"XCTest: {summary['passedTests']} passed, {summary.get('skippedTests', 0)} skipped")
