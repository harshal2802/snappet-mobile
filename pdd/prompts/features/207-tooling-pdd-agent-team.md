# Prompt: PDD agent team (prompt 207)

**File**: pdd/prompts/features/207-tooling-pdd-agent-team.md
**Created**: 2026-10-29
**Project type**: Tooling (Claude Code agents + skill) — no app code.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`, `CLAUDE.md`

## Goal

Run each PDD job with a small team of Claude Code agents instead of one long session: a planner writes the
prompt, an iOS builder and an Android builder implement it in parallel, a reviewer runs the gates, and a
scribe keeps context, decisions, and the knowledge graph true. The standing rules in `CLAUDE.md` (prompt
first, graph and decisions in the same change, platform-free engine) become steps an agent owns, so they
don't depend on one session remembering them.

This is the Snappet instance of a "team" workflow proposed for `harshal2802/pdd-skill`
(`docs/agent-team/upstream-pdd-skill.md`). When that ships, the generic role agents move upstream and this
repo keeps only `pdd/context/team.md`.

## Approach

- **One roster file** (`pdd/context/team.md`): roles, the PDD workflows each runs, write scopes, gates per
  path, what can't run on Linux, scribe checklist, stop points. Agents read it, so changes happen in one
  place.
- **Lead = main session** via a project skill (`.claude/skills/pdd-team/`), because subagents can't launch
  subagents.
- **Thin role agents** (`.claude/agents/`): `pdd-planner`, `ios-builder`, `android-builder`,
  `pdd-reviewer`, `pdd-scribe`.
- **Handoffs through `pdd/` files**, not chat: the plan, the feature prompt, the review notes.
- **Builders run in separate worktrees**; the reviewer enforces write scopes with `git diff --name-only`.
- `.gitignore` keeps local `.claude/` state ignored but commits `agents/` and `skills/`.

## Output

- `pdd/context/team.md`
- `.claude/skills/pdd-team/SKILL.md`
- `.claude/agents/{pdd-planner,ios-builder,android-builder,pdd-reviewer,pdd-scribe}.md`
- `.gitignore`: `.claude/*` with `!.claude/agents/` and `!.claude/skills/`
- `docs/agent-team/pdd-team-mode.html`: the explainer diagrams
- `docs/agent-team/upstream-pdd-skill.md`: the proposed `pdd-skill` change
- `pdd/context/decisions.md`: dated entry

## Acceptance criteria

- [x] `git check-ignore` ignores `.claude/settings.local.json` and does not ignore `.claude/agents/*.md` or
      `.claude/skills/pdd-team/SKILL.md`.
- [x] Every agent file has `name`, `description`, and `tools` frontmatter, and its `name` matches the roster.
- [x] The engine platform-import gate in `team.md` runs and prints nothing on the current `main`.
- [ ] First real job run through `/pdd-team` on the Mac, with all gates actually run (not done yet).
- [x] No app code, schema, or user-facing behavior changes, so no knowledge-graph edit.

## Constraints

- On-device-only rule is unaffected; this is developer tooling.
- Write scopes are enforced by instructions plus the reviewer's diff check, not by Claude Code itself.
  Say so; don't present them as hard sandboxing.

## Test plan

1. `git check-ignore -v .claude/settings.local.json .claude/agents/ios-builder.md` → only the first is ignored.
2. On the Mac: `claude`, then `/pdd-team` with a small real job, and check the report lists each gate with
   output.
