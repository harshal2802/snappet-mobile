# Proposal: a `team` workflow for pdd-skill

Target repo: [harshal2802/pdd-skill](https://github.com/harshal2802/pdd-skill). Snappet runs a local
version of this first (prompt 207); this is what moving it upstream would look like.

## Why it belongs in pdd-skill

pdd-skill already defines who does what in a PDD job; it just assumes one agent does all of it. Its own
transitions say "Prompts → run the prompt 2 to 3 times → Review". Team mode gives each step an owner and
fills the one step no workflow owns: running the prompt.

| Role | Existing pdd-skill workflows |
|---|---|
| Lead | `status`, the routing table |
| Planner | `research`, `plan`, `prompts`, `update` |
| Builder (one per platform) | none: "run the prompt" |
| Reviewer | `review`, `eval` |
| Scribe | `context` |

## Multi-provider design

pdd-skill ships to Claude Code, Copilot, Codex, and Antigravity, and not all of them can launch parallel
subagents. So the core workflow describes **roles and handoff files**, and each adapter decides how roles run:

- **Claude Code:** roles are plugin agents; `/project:pdd-team` makes the main session the lead and
  launches builders in parallel worktrees.
- **Providers without subagents:** the same roles run one after another in one session ("switch hats"),
  passing the same files. The output is identical, just slower.

That works because roles talk through `pdd/` files (plan, prompt, review notes), never through chat.

## Project specifics: `pdd/context/team.md`

A new optional context file, written by `init` or `context`: the roster, write scope per role, gate commands
per path, environment limits, and stop points. Generic agents read it, so projects don't fork agent files.
Snappet's is the reference example (`pdd/context/team.md`).

## Files to change (per the pdd-skill CLAUDE.md "adding a new workflow" rule)

1. `core/metadata/workflows.json`: add `team` (`kind: workflow`, category `building-features`) with
   commands for all four providers.
2. `core/workflows/team.md`: the provider-neutral loop (size → prompt → build → gate → fix → context →
   report), the roles table, the `team.md` format, and the honesty rules (unrun gate = "not verified").
3. `core/metadata/adapter-docs.json`, `claude-skill.json`, `help.json`, `routing.json`: the title, overview
   line, transitions ("Review – looks good → Team next time"), a help scenario ("Ship a feature end to end"),
   and routing signals ("ship this", "have the team do it").
4. `providers/claude/agents/`: `pdd-planner.md`, `pdd-builder.md` (generic; platform comes from `team.md`),
   `pdd-reviewer.md`, `pdd-scribe.md`, plus `agents` in `plugin.json` if the manifest needs it.
5. `core/workflows/init.md` / `context.md`: offer to write `pdd/context/team.md`.
6. Run `python3 scripts/render_workflow_tables.py`, then `bash tests/consistency.sh` and
   `bash tests/test-hooks.sh`.

That repo's `CLAUDE.md` says commits there carry no Co-Authored-By trailer.

## Open questions

- Is `team` a workflow or a utility? It mostly chains other workflows, like `help` and `status`.
- One generic `pdd-builder` reading the platform from `team.md`, or let projects add named builders as
  Snappet does?
- Does Codex's plugin format support subagents yet, or does it use the switch-hats path?
