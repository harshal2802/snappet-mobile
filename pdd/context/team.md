# Team: Snappet Mobile

**Last updated**: 2026-10-29

The roster for PDD team mode (prompt 207). Each role is a Claude Code subagent in `.claude/agents/`; the
lead is the main session running the `pdd-team` skill. The agent files stay generic and read **this file**
for everything Snappet-specific, so a role's scope, gates, or limits change here and nowhere else.

Roles hand off through **files in `pdd/`**, not chat: the plan, the feature prompt, the review notes. Any
role (or a human) can pick a job up from those files alone.

## Roles

| Role | Agent | PDD workflows it runs | May write | Never touches |
|---|---|---|---|---|
| Lead | main session + `.claude/skills/pdd-team/` | status, routing | nothing; delegates | code, docs |
| Planner | `pdd-planner` | research, plan, prompts, update | `pdd/prompts/**`, `docs/ux-research/**` | app code |
| iOS builder | `ios-builder` | runs one feature prompt | `ios/**` | `android/**`, `pdd/context/**` |
| Android builder | `android-builder` | runs one feature prompt | `android/**` | `ios/**`, `pdd/context/**` |
| Reviewer | `pdd-reviewer` | review, eval | `**/*Tests*/**`, `pdd/evals/**` | app code outside tests |
| Scribe | `pdd-scribe` | context | `pdd/context/**`, `docs/knowledge-graph/data.js`, `README.md` | code |

Two builders never run on the same files. When a job touches `ios/App/Shared/` (the phone/watch/widget
wire types), the iOS builder owns it and the Android builder waits for it.

## Gates (the reviewer runs these; output is pasted, never summarized)

| Change touches | Gate | Runs on Linux? |
|---|---|---|
| `ios/HighlightEngine/**` | `make engine-test` | only where Swift is installed |
| `ios/App/**` | `make ios-test-unit` (`make ios-test` for UI flows) | **no, macOS + Xcode only** |
| `android/**` | `make android-test`, `make android-lint` | yes (JDK + Android SDK) |
| any engine file | the platform-import check below prints nothing | yes |

```sh
grep -rnE 'import (HealthKit|AVFoundation|Photos|UIKit|SwiftUI)' ios/HighlightEngine/Sources
```

On Linux or in a cloud session, every iOS gate is reported as **"not verified here"**, never as passing.

## Scribe checklist (from `CLAUDE.md`)

- A new screen, sheet, service, watch surface, widget, or navigation edge → a `nodes` entry plus a `links`
  edge in `docs/knowledge-graph/data.js`.
- A non-obvious choice → a dated entry at the top of `pdd/context/decisions.md`.
- A change to what exists → `pdd/context/project.md` stays true.
- A new persisted model → the backup tripwire (`SnappetSchema` / `SnappetBackup`) is called out to the lead.

## Stop points (only the human does these)

- Pushing to `main`, merging, or opening a PR.
- `make ios-release`, `make ios-release-alpha`, `make release`, or any TestFlight / Play upload.
- Posting on GitHub.
- Changing `pdd/context/decisions.md` entries older than today (append new ones instead).
