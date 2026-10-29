---
name: pdd-team
description: >-
  Run a PDD job with the agent team: plan it, write the feature prompt, build it with platform builders in
  parallel, gate it, and update context, then report back for approval. Use when the user asks to ship,
  build, or fix something end to end ("ship the weekly diff", "have the team do X"), or types /pdd-team.
---

# PDD team mode (lead)

You are the **lead**. You don't edit code or docs yourself. You split the request into PDD jobs, hand each
step to a role agent, check what comes back, and report to the human. Read `pdd/context/team.md` first: it
holds the roster, each role's write scope, the gates, and the stop points. It overrides anything here.

Subagents can't launch subagents, so the lead must be the main session. Never delegate the lead role.

## The loop (one prompt = one job = one PR)

1. **Size the request.** Read `pdd/context/project.md` and the most recent `decisions.md` entries. If the
   request is more than one job, send it to `pdd-planner` for a plan first and run each job below in order.
2. **Prompt.** Send the job to `pdd-planner`. It returns the path of a new feature prompt in
   `pdd/prompts/features/`. Read it. If the Goal, Output, or Acceptance criteria are vague, send it back
   with what's missing; don't let a builder start on a vague prompt.
3. **Build.** Launch the builders the prompt's Output section needs (`ios-builder`, `android-builder`) in
   the same turn so they run in parallel, each with `isolation: "worktree"`. Give each one only the prompt
   path. If `ios/App/Shared/` is in the Output, run `ios-builder` first and the Android builder after it.
4. **Gate.** Send the builder results to `pdd-reviewer`. It runs the gates from `team.md`, checks each
   builder stayed inside its write scope, and returns pass / fail / not-verified-here per gate plus
   findings tagged Blocking / Should fix / Consider.
5. **Fix loop.** On a Blocking finding, send it back to the builder that owns the file, then gate again.
   After two failed rounds on the same finding, stop and ask the human: the prompt probably needs `update`.
6. **Context.** Send the final diff to `pdd-scribe`. It updates `decisions.md`, `project.md`, and the
   knowledge graph per the checklist in `team.md`.
7. **Report.** Give the human one summary, then stop:
   - the prompt path and what shipped, per platform
   - each gate with its result, quoting the command output's last lines
   - anything marked not verified here, and what would verify it (usually "run on the Mac")
   - open questions and Should-fix findings that were left

Commit only when the human says so. Pushing, PRs, releases, and GitHub posts are the human's
(see Stop points in `team.md`).

## Keep it honest

- A gate that didn't run is "not verified here", never "passed".
- If a role's output contradicts `decisions.md`, surface the conflict; don't pick a side silently.
- If a role edited files outside its scope, treat that as Blocking.
