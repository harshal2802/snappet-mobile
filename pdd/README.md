# PDD layer — Snappet Mobile (iOS)

This repo uses **Prompt-Driven Development**: features and spikes are specified as committed prompts,
and the AI-generated output is reviewed before it lands. The prompt is part of the codebase.

## How this relates to the web repo

The web repo [harshal2802/Snappet](https://github.com/harshal2802/Snappet) is the **product brain** —
it owns the deep research (issue [#60](https://github.com/harshal2802/Snappet/issues/60)), the
cross-platform initiative plan (`PLAN-snappet-mobile.md`), and the **canonical Snappet Core schema**.
This `pdd/` layer owns the **iOS implementation**: how the code here is built and the prompt chain that
drives it. When in doubt, the web repo wins for product/schema; this layer wins for iOS conventions.

## Layout

```
pdd/
  context/
    project.md                  What we're building + the reality-based current state. START HERE.
    conventions.md              How the Swift/SwiftUI code is written (the layering rule, naming, testing).
    decisions.md                Non-obvious choices already baked in — don't re-litigate them.
    snappet-core-schema.md      iOS mirror of the canonical schema (maps contract → engine types).
    research/                   Captured research notes (mostly lives in the web repo's #60).
  prompts/
    features/                   Shippable-code prompts.
      PLAN-ios-to-shippable.md  The v0.1 → v1 prompt chain. The roadmap for this repo.
    experiments/                Throwaway spike prompts (decision, not product).
    templates/feature-prompt.md Copy this to start a new feature prompt.
  evals/                        Prompt-quality tracking (scripts/, baselines/) — add as prompts mature.
```

## Workflow (quick path)

1. **Context** — keep `context/` true to reality. Stale context misleads every future prompt.
2. **Plan** — see `prompts/features/PLAN-ios-to-shippable.md`; author one prompt per phase.
3. **Prompt** — copy `templates/feature-prompt.md`, fill it in, commit it.
4. **Run** the prompt, then **Review** the output before committing (engine changes need `swift test`).
5. Record any non-obvious decision in `decisions.md` the same day.

One prompt = one job = one PR. Commit the prompt alongside the output it produced.
