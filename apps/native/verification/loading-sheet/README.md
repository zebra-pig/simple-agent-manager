# New project sheet loading regression

The reported screenshot shows an inline Form row holding a spinner. Removing
that row moves every section above it. The production view before PR #53
(commit `94087a71f9ba95197cdcb76a1698aa5651ba4b54`) reproduces the symptom:

| Phase | Project name field Y position (points) |
| --- | ---: |
| Initial load | 292.0 |
| Loaded | 187.3333 |
| Repository reload | 292.0 |
| Reload complete | 187.3333 |

The maximum movement is **104.6667 points**. The same production sheet on
current main keeps that field at **187.3333 points in all four phases**.
This checks the actual `ProjectSettings` view inside `.sheet`, not a standalone
progress helper or another screen. Only the model boundary is scripted, so the
request can be held while the view settles. UIKit measures the actual project
name text field in window coordinates. The runner fails for any movement >1pt.

## What the earlier validation missed

The earlier change removed the inline row in source, but its verification did
not measure this sheet's transition and did not execute the Xcode Cloud
preparation script. That script separately compiles `FileBrowserView.swift` for
native render checks. Adding `.initialLoading` and `LoadingLabel` introduced a
dependency on `Loading.swift`, which was omitted from that compile invocation.
A local Xcode app build includes every source and therefore missed this failure.

Apple's build history confirms run **88**, for PR #53's merge commit
`23978c5e27bb268149cb13e5cfb14dc11a0ba7af`, failed its macOS archive action in
`ci_post_clone.sh`. The iOS archive succeeded and iOS TestFlight build 88 is
VALID. The screenshot alone does not identify the installed build; a failed
macOS action does not establish which iOS build the user ran.

This follow-up includes `Loading.swift` in the standalone compile and runs the
sheet regression from the macOS Xcode Cloud preparation action. A future
reintroduction of an inline loading row now fails the release preparation step.
The test creates/deletes its own simulator and uses no live account or API.

## Evidence

- [Before loading](before/initial-sheet.png), [before loaded](before/loaded-sheet.png)
- [After loading](after/initial-sheet.png), [after loaded](after/loaded-sheet.png)
- [After refresh](after/refreshing-sheet.png), [after refresh completion](after/refreshed-sheet.png)
- [Before measurements](before/result.txt), [after measurements](after/result.txt)

The old production view is a negative control: the shell runner exits 1 and
reports the 104.6667pt shift. Current production view exits 0 and reports 0pt.
The standalone files render compile fails without `Loading.swift` and passes
with it; the resulting Files/Git render fixture also runs successfully.

## Reproduce on a Mac

Run `sh apps/native/ios/tests/ui/project-loading/project-loading.sh /absolute/evidence/directory`.
It selects an installed iOS runtime and a supported iPhone model, creates an
isolated simulator, compiles production `ProjectSettings.swift`, `Loading.swift`
and `Platform.swift` with the scripted boundary, and captures all four phases.
It terminates/uninstalls the fixture and deletes its simulator on exit.
`SAM_TEST_SIMULATOR_UDID` can select an existing booted simulator instead.

For the negative control, extract the old production view from commit
`94087a71f9ba95197cdcb76a1698aa5651ba4b54` to a temporary file and supply its path
as `SAM_TEST_PROJECT_SETTINGS_SOURCE`. The expected result is FAIL and exit 1.
The boundary does not change installation availability during the request, so
these measurements isolate loader-caused movement from actual returned data.

The test covers initial load and reload, not project submission or deletion.
