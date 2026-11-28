# compat-regressions

`scripts/compat-regressions.py` reads the compat export's store (`reports/*.ndjson` on the
`compat-data` branch, [compat-export.md](compat-export.md)) and keeps one GitHub issue, labelled
`regression-watch`, per game that ran well on older builds and does not run on a newer one.
`.github/workflows/compat-regressions.yml` runs it daily after the export's full refresh.

```sh
scripts/compat-regressions.py out --issues issues.json   # dry run on a saved issue list
GITHUB_TOKEN=… scripts/compat-regressions.py out          # dry run against GitHub
GITHUB_TOKEN=… scripts/compat-regressions.py out --apply  # make the changes
make compat-regressions-check                            # the fixture tests
```

The workflow is off by default: it prints the plan to the job summary. The repository variable
`BRIDGEPLAY_REGRESSION_ISSUES=on`, or a dispatch with `apply`, lets it change issues. It needs
only the workflow's `GITHUB_TOKEN` (`issues: write`).

## When a game counts

The export's verdict decides: a game regressed when its verdict is `broken_since` (rule 1, the
same window, one vote per Mac and thresholds). The script imports `compat-export.py` and adds no
rule of its own. A break on a Steam client build is tracked the same way once reports carry it.

## The issue

- Title: `Regression: <game> did not run since <version>`.
- The counted Macs per build (ran well, had issues, did not run), the top three log signatures of
  the failing reports on the broken build or newer (the `sig` the signature board groups by, with
  the known cause when there is one), the most common engine and backend, and links to up to six
  reports.
- A hidden marker, `<!-- bridgeplay-regression-watch appid=… key=build|steam since=… state=… -->`,
  ties the issue to the game. The script rewrites the body on each run; people comment below.

## What each run does

| Now | Issue | Run |
|---|---|---|
| regressed | none | open one (at most 5 per run, worst first; the rest wait) |
| regressed | open | edit when the evidence changed; comment when the broken build moved |
| regressed | closed, same build | nothing: a maintainer's close stands |
| regressed | closed, other build | reopen and comment |
| not regressed, a Mac ran it well on that build or newer after it first failed | open | comment with the report and close (`state=recovered`) |
| not regressed, no such report | open | comment once and mark it `state=quiet`; it stays open |
| no reports left | any | nothing |

Nothing is posted when a title or body would match the export's personal-data patterns.
