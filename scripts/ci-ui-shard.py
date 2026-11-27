#!/usr/bin/env python3
"""Choose and split the SnappetUITests classes for CI (prompts 261, 268).

    scripts/ci-ui-shard.py <index> <count>      # leg K of N of the FULL suite: one `-only-testing:SnappetUITests/<Class>` per line
    scripts/ci-ui-shard.py --plan <count>       # every full-suite leg with its classes and test counts
    scripts/ci-ui-shard.py --check [<count>]    # exits 1 unless: every test class is in exactly one full-suite leg; no UI
                                                # test has an async setUp / tearDown / test (they are never retried); every
                                                # class is in an area or the smoke set; every area pattern matches something;
                                                # the ci.yml fallback matrix is the full suite
    scripts/ci-ui-shard.py --select <file>      # the plan for a list of changed paths (one per line, `-` = stdin)
          [--push]                              #   as for a push to main (the recipe files do not force the full suite)
    scripts/ci-ui-shard.py --matrix <file> [--push] [--fallback full|smoke] [--labels "a,b"]
                                                # the `app` job's matrix (JSON) for those paths; on any error or an empty
                                                # list it prints the fallback (default full); the PR's
                                                # labels full-ui / ui-quick override the paths
    scripts/ci-ui-shard.py --matrix --full      # the full matrix: SnappetTests + SnappetUITests-1of8 … 8of8
    scripts/ci-ui-shard.py --matrix --smoke     # SnappetTests + the smoke leg (also the `ui-quick` PR label)
    scripts/ci-ui-shard.py --matrix --classes "A,B"
                                                # SnappetTests + exactly those classes (a manual dispatch's ui_classes);
                                                # exits 2 on an unknown class: deliberately not fail-open
    scripts/ci-ui-shard.py --only "<A B …>"     # `-only-testing:` lines for those classes; exits 2 if one does not exist
    scripts/ci-ui-shard.py --areas              # the area map with its classes and test counts

Classes are found by reading the sources (no build needed): each `class X: XCTestCase` with at least one
`func test…`. A class is weighted by its number of tests and placed, heaviest first, on the lightest leg so far
(ties: lowest leg, then class name), so a split is the same on every machine and a new test class lands in a leg
without anyone editing a list.

What a change runs (prompt 268; the full suite is ~8 h of machine time, so it no longer runs on every PR):
  - `.github/workflows/ci.yml` or this script changed (on a PR)        → the full suite, 8 legs
  - a UI test file changed                → its classes, plus every class that uses what it declares (helpers:
                                            UITestTaps, RacketPlayerControls, TestStoreGuard, …; found by grepping
                                            for the helper's type / function names); a helper nobody can be shown to
                                            use → the full suite
  - an app file inside an AREA (below)    → that area's classes
  - any other `ios/**` file (Core, Services, DesignSystem, Shared, project.yml, HighlightEngine sources, …)
                                          → the smoke set only; the nightly full run covers the rest
  - unit-test sources and docs under ios/ → nothing extra (they cannot change the app or the UI tests)
  - nothing under ios/                    → no UI legs at all
On a PR the label `full-ui` runs the full suite and `ui-quick` runs the smoke set only, whatever changed (both:
full-ui wins). A manual dispatch runs the full suite, or exactly its `ui_classes`. (Labels and inputs are read by
the workflow, which then asks this script for `--matrix --full / --smoke / --classes`.)
The smoke set is added whenever any UI runs. Selected classes are split into ceil(tests / 35) legs; a selection
that needs 8 legs or more runs as the full suite.
"""
import fnmatch
import json
import math
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
UI_DIR = "ios/App/SnappetUITests"
ROOT = REPO / UI_DIR
WORKFLOW = REPO / ".github" / "workflows" / "ci.yml"

FULL_LEGS = 8          # legs of the full suite; the `app` matrix fallback in ci.yml must list the same (--check)
TESTS_PER_LEG = 35     # a targeted run gets ceil(tests / 35) legs (the full suite is ~37 per leg)

# Changes to these rebuild how the UI suite is chosen and run: a PR that changes them runs everything.
RECIPE = [".github/workflows/ci.yml", "scripts/ci-ui-shard.py"]

FULL_LABEL = "full-ui"     # PR label: the full suite
QUICK_LABEL = "ui-quick"   # PR label: unit + engine + smoke only, whatever changed (full-ui wins if both)

# Under ios/ but unable to change the app or the UI tests: no UI leg for them.
INERT = [
    "ios/App/SnappetTests/*",
    "ios/HighlightEngine/Tests/*",
    "ios/*.md",
]

# Always run when any UI runs (~6 tests, ~5 min of tests on the runner at ~45 s a test; worst case under 10).
# SuiteSmokeTests opens every module from the App Library; TestStoreGuardUITests is the guard every UI test leans on;
# WorkoutDashboardUITests opens the seeded Gym Tracker and History; FeedViewUITests renders the Recap tab.
SMOKE = ["SuiteSmokeTests", "TestStoreGuardUITests", "WorkoutDashboardUITests", "FeedViewUITests"]

APP = "ios/App/Snappet"
WT = f"{APP}/Features/WorkoutTracker"

# area → app paths (fnmatch, `*` also crosses `/`), paths taken back out of it, and its UI test classes (fnmatch on
# class names). A class may be in more than one area (it runs when either is touched).
AREAS = {
    "racket": {
        "paths": [f"{WT}/Racket*", f"{APP}/Services/Racket*", "ios/App/Shared/Racket*"],
        "classes": ["Racket*", "LiveSessionSafetyUITests"],
    },
    "workout": {
        "paths": [f"{WT}/*", f"{APP}/Services/Workout*"],
        "not": [f"{WT}/Racket*"],
        "classes": [
            "Activity*UITests", "Workout*", "Library*UITests", "ClimbAttemptTimerTests", "CompletionMomentTests",
            "DanceOtherTests", "EditClimbTests", "FreeformFlowWalkthroughTests", "GuidePhotoUITests",
            "HeartRateOwnershipUITests", "LiveClimbStatsTests", "LiveSessionSafetyUITests",
            "LiveWorkoutStudioWalkthroughTests", "NamedClimbTests", "PreviousClimbSetterPhotosTests",
            "QuickAddSetTests", "QuickSessionPagerUITests", "RepeatSetTests", "RoutineScheduleUITests",
            "RunDisciplineTests", "SessionInsightsUITests", "StrengthEditTests", "StructuredIntervalRunnerTests",
            "TimedSetTimerTests", "TimedStrengthSetTests", "TrackingTypeFilterTests",
            "RacketMixedSessionUITests",   # a racket match and lifts in one session: the workout session detail
        ],
    },
    "studio": {   # the Studio's render path; its golden frames are unit tests, these are the screens (prompt 304)
        "paths": [f"{WT}/Studio*", f"{APP}/Services/Studio*", f"{APP}/Features/Settings/StudioSelfCheck*",
                  "ios/App/SnappetTests/GoldenFrames/*"],
        # PhotosAccessGrantUITests skips itself here; CI runs it for real in the SnappetTests leg (prompt 322).
        "classes": ["StudioSelfCheckUITests", "StudioHRTimingUITests", "LiveWorkoutStudioWalkthroughTests",
                    "PhotosAccessGrantUITests"],
    },
    "kilter": {
        "paths": [f"{APP}/Features/Kilter/*", f"{APP}/Services/Kilter*", "ios/App/Shared/Kilter*"],
        "classes": ["Kilter*", "LibraryKilterUITests", "HeartRateOwnershipUITests"],
    },
    "feed": {   # Recap, Clips, sharing, reels
        "paths": [f"{APP}/Features/Feed/*", f"{APP}/Features/Reel/*"],
        "classes": ["Feed*UITests", "Clips*UITests", "Recap*UITests", "ShareComposerUITests"],
    },
    "festival": {"paths": [f"{APP}/Features/Festival/*"], "classes": ["FestivalUITests"]},
    "household": {
        "paths": [f"{APP}/Features/Household/*", f"{APP}/Services/Household*", "ios/App/Shared/Household*"],
        "classes": ["Household*Tests"],
    },
    "expense": {"paths": [f"{APP}/Features/Expense/*"], "classes": ["ExpenseUITests"]},
    "budget": {"paths": [f"{APP}/Features/Budget/*"], "classes": ["BudgetUITests"]},
    "tip": {"paths": [f"{APP}/Features/Tip/*"], "classes": ["TipUITests"]},
    "habit": {"paths": [f"{APP}/Features/Habit/*"], "classes": ["HabitUITests", "RoutineScheduleUITests"]},
    "journal": {"paths": [f"{APP}/Features/Journal/*"], "classes": ["JournalUITests"]},
    "pomodoro": {
        "paths": [f"{APP}/Features/Pomodoro/*", f"{APP}/Services/Pomodoro*", "ios/App/Shared/Pomodoro*"],
        "classes": ["PomodoroUITests"],
    },
    "progression": {   # training buddy
        "paths": [f"{APP}/Features/Progression/*"],
        "classes": ["ProgressionUITests", "Buddy*Tests"],
    },
    "wardrobe": {"paths": [f"{APP}/Features/Wardrobe/*", f"{APP}/Services/Wardrobe*"], "classes": ["WardrobeUITests"]},
    "backup": {
        "paths": [f"{APP}/Features/Backup/*"],
        # The *Device* classes need a real phone, Photos and Google Drive: each test skips itself on
        # the simulator. They are listed so every class has a home (the coverage check).
        "classes": ["BackupUITests", "CloudBackupDeviceUITests", "GoogleDeviceUITests", "ClipCopiesDeviceUITests",
                    "ClipCopyActionsDeviceUITests", "ClipRoundTripDeviceUITests", "MediaLinkDeviceUITests"],
    },
    "camera": {
        "paths": [f"{APP}/Features/Camera/*", f"{APP}/Services/CameraController.swift"],
        "classes": ["SnappetCameraUITests"],
    },
    "settings": {"paths": [f"{APP}/Features/Settings/*"], "classes": ["AppearanceUITests", "StudioSelfCheckUITests"]},
    "home": {"paths": [f"{APP}/Features/Home/*"], "classes": ["HomeLinksUITests"]},
    "shell": {   # tab bar + App Library
        "paths": [f"{APP}/Features/Shell/*", f"{APP}/Features/AppLibrary/*"],
        "classes": ["SuiteSmokeTests", "HomeLinksUITests", "FeedViewUITests"],
    },
    "screenshots": {"paths": ["ios/App/fastlane/*"], "classes": ["SnappetSnapshotTests"]},
}

CLASS = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+)?(?:final\s+)?class\s+(\w+)\s*:\s*[^{]*\bXCTestCase\b")
TEST = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+)?func\s+test\w*\s*\(")
# An async setUp / tearDown / test in a UI test class: when it fails with `continueAfterFailure = false`, the test
# runner exits and xcodebuild restarts it at the NEXT test, so `-retry-tests-on-failure` never retries it (prompt 267).
ASYNC = re.compile(r"\bfunc\s+(setUp|tearDown|test\w*)\s*\([^)]*\)\s*async\b")
# Declarations a helper file shares with the test files (see `exported_symbols`).
DECL = re.compile(r"^\s*((?:@\w+(?:\([^)]*\))?\s+|(?:public|internal|private|fileprivate|static|class|final|"
                  r"mutating|nonisolated)\s+)*)(struct|enum|class|protocol|typealias|extension|func|var|let)\s+(\w+)")
EXTENSION = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate)\s+)?extension\b")


# ── the sources ───────────────────────────────────────────────────────────────────────────────────────────────────


class Tree:
    """The UI test sources: {file name: text}. Loaded from disk by default; tests pass their own."""

    def __init__(self, files=None):
        if files is None:
            files = {p.relative_to(ROOT).as_posix(): p.read_text(encoding="utf-8") for p in sorted(ROOT.rglob("*.swift"))}
        self.files = dict(sorted(files.items()))

    def classes_by_file(self):
        """{file: {class: number of tests}}, classes with tests only."""
        out = {}
        for name, text in self.files.items():
            found, current = {}, None
            for line in text.splitlines():
                m = CLASS.match(line)
                if m:
                    current = m.group(1)
                    found.setdefault(current, 0)
                elif current and TEST.match(line):
                    found[current] += 1
            out[name] = {c: n for c, n in found.items() if n > 0}
        return out

    def classes(self):
        """{class name: number of test methods}, for classes that have tests."""
        out = {}
        for found in self.classes_by_file().values():
            out.update(found)
        return out


def classes():
    return Tree().classes()


def async_hooks(tree=None):
    """["File.swift:line: text"] for every async setUp / tearDown / test in the UI tests."""
    found = []
    for name, text in (tree or Tree()).files.items():
        for n, line in enumerate(text.splitlines(), 1):
            if ASYNC.search(line):
                found.append(f"{name}:{n}: {line.strip()}")
    return found


def exported_symbols(text):
    """Regexes that find a use of what this file declares for other files.

    Top level: a type (`\\bName\\b`) or a free function (`name(` not after a `.`). Inside an `extension` (of
    XCUIApplication, XCUIElement…): a member, as `.name` or as a bare call; a function whose later parameters have
    no default must be called with their labels on the same line, so `tap(_:until:)` is told apart from `.tap()`.
    Members of test classes and of other types are not exported (they are reached through the type). Private and
    fileprivate declarations are skipped."""
    pats, depth, in_ext = [], 0, False
    for line in _code_lines(text):
        m = DECL.match(line)
        if m and "private" not in m.group(1):
            kind, name = m.group(2), m.group(3)
            if depth == 0 and kind in ("struct", "enum", "class", "protocol", "typealias") and not CLASS.match(line):
                pats.append(re.compile(rf"\b{name}\b"))
            elif depth == 0 and kind == "func":
                pats.append(_call(name, line, member=False))
            elif depth == 1 and in_ext and kind == "func":
                pats.append(_call(name, line, member=True))
            elif depth == 1 and in_ext and kind in ("var", "let"):
                pats.append(re.compile(rf"\.{name}\b|(?<![.\w]){name}\b"))
        if depth == 0:   # each top-level line decides whether the members that follow are an extension's
            in_ext = bool(EXTENSION.match(line)) and "private" not in line
        depth = max(0, depth + line.count("{") - line.count("}"))
    return pats


def _code_lines(text):
    """Lines without `//` comments and string literals (so a brace in a string does not move the depth)."""
    for line in text.splitlines():
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        yield line.split("//", 1)[0]


def _call(name, line, member):
    params = line.split("(", 1)[1] if "(" in line else ""
    labels = []
    for i, p in enumerate(_split_params(params)):
        if i == 0 or "=" in p or ":" not in p:
            continue
        labels.append(p.split(":", 1)[0].split()[0])
    before = r"(?:\.|(?<![.\w]))" if member else r"(?<![.\w])"
    tail = "".join(rf".*\b{re.escape(lbl)}:" for lbl in labels if lbl != "_")
    return re.compile(rf"{before}{name}\({tail}")


def _split_params(params):
    out, depth, cur = [], 0, ""
    for ch in params:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            if depth == 0:
                break
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [p.strip() for p in out]


def users_of(name, tree):
    """The classes whose files use what UI test file `name` declares, following helpers that use helpers."""
    by_file = tree.classes_by_file()
    pats = exported_symbols(tree.files[name])
    if not pats:
        return set()
    seen, todo, users = {name}, [name], set()
    while todo:
        pats = exported_symbols(tree.files[todo.pop()])
        for other, text in tree.files.items():
            if other in seen:
                continue
            code = "\n".join(_code_lines(text))
            if any(p.search(code) for p in pats):
                seen.add(other)
                if by_file[other]:
                    users |= set(by_file[other])
                else:
                    todo.append(other)   # a helper that uses a helper: its users are users too
    return users


# ── areas and selection ─────────────────────────────────────────────────────────────────────────────────────────────


def _match(path, patterns):
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def areas_of(path):
    return [a for a, spec in AREAS.items() if _match(path, spec["paths"]) and not _match(path, spec.get("not", []))]


def area_classes(area, every):
    return {c for c in every if _match(c, AREAS[area]["classes"])}


class Plan:
    def __init__(self, mode, reasons, areas=(), classes=None, legs=None):
        self.mode = mode            # "none" | "smoke" | "targeted" | "picked" | "full"
        self.reasons = list(reasons)
        self.areas = sorted(set(areas))
        self.classes = classes or {}   # {class: tests}
        self.legs = legs or []         # [(suite name, [(class, tests)])]

    def matrix(self):
        rows = [{"suite": "SnappetTests"}]
        for suite, members in self.legs:
            row = {"suite": suite}
            if self.mode != "full":
                row["classes"] = " ".join(c for c, _ in members)
            rows.append(row)
        return rows


def split(weights, count):
    """Deal {class: tests} into `count` balanced legs: heaviest first onto the lightest leg (ties: lowest leg)."""
    out = [[] for _ in range(count)]
    load = [0] * count
    for name, n in sorted(weights.items(), key=lambda kv: (-kv[1], kv[0])):
        i = min(range(count), key=lambda k: (load[k], k))
        out[i].append((name, n))
        load[i] += n
    return [sorted(s) for s in out]


def shards(count, tree=None):
    return split((tree or Tree()).classes(), count)


def full_plan(reasons, tree=None):
    every = (tree or Tree()).classes()
    legs = [(f"SnappetUITests-{i}of{FULL_LEGS}", s) for i, s in enumerate(split(every, FULL_LEGS), 1)]
    return Plan("full", reasons, classes=every, legs=legs)


def smoke_plan(reasons, tree=None):
    every = (tree or Tree()).classes()
    chosen = {c: every[c] for c in SMOKE if c in every}
    return Plan("smoke", reasons, classes=chosen, legs=[("SnappetUITests-smoke", sorted(chosen.items()))])


def picked_plan(names, tree=None):
    """Exactly the named classes (a manual dispatch's `ui_classes`), no smoke, split with the usual rule (capped at
    FULL_LEGS legs). Unknown or no names raise ValueError: this is the one choice that must NOT fail open — a typo
    must not become a 2-hour full run or an empty one."""
    every = (tree or Tree()).classes()
    names = [n for n in re.split(r"[\s,]+", names) if n] if isinstance(names, str) else list(names)
    unknown = sorted({n for n in names if n not in every})
    if unknown or not names:
        raise ValueError(f"no such UI test class: {', '.join(unknown)}" if unknown else "no UI test classes given")
    picked = {n: every[n] for n in sorted(set(names))}
    legs = min(FULL_LEGS, math.ceil(sum(picked.values()) / TESTS_PER_LEG))
    names = [f"SnappetUITests-picked-{i}of{legs}" for i in range(1, legs + 1)]
    return Plan("picked", [f"picked by hand: {' '.join(picked)}"], classes=picked,
                legs=list(zip(names, split(picked, legs))))


def label_plan(labels, tree=None):
    """A PR label's override, or None. `full-ui` → the full suite; `ui-quick` → smoke only, even for a change to the
    CI recipe; both → full-ui (fail toward more testing). `labels`: names, or one string split on commas."""
    labels = {lbl.strip() for lbl in (labels.split(",") if isinstance(labels, str) else labels) if lbl.strip()}
    if FULL_LABEL in labels:
        return full_plan([f"the PR has the {FULL_LABEL} label"], tree)
    if QUICK_LABEL in labels:
        return smoke_plan([f"the PR has the {QUICK_LABEL} label: smoke only, whatever changed"], tree)
    return None


def select(paths, push=False, tree=None):
    """The plan for a list of changed repo paths. `push`: a push to main (the recipe files don't force the full
    suite there: the PR already ran it, and the nightly runs it again)."""
    tree = tree or Tree()
    by_file = tree.classes_by_file()
    every = tree.classes()
    paths = sorted({p.strip() for p in paths if p.strip()})
    if not paths:
        raise ValueError("no changed paths")
    chosen, areas, reasons, ui = set(), set(), [], False
    for path in paths:
        if path in RECIPE:
            if not push:
                return full_plan([f"{path}: the CI recipe changed"], tree)
            reasons.append(f"{path}: CI recipe (validated on its PR; push runs smoke)")
            ui = True
            continue
        if not path.startswith("ios/") or _match(path, INERT):
            continue
        ui = True
        if path.startswith(UI_DIR + "/"):
            name = path[len(UI_DIR) + 1:]
            if not name.endswith(".swift"):
                return full_plan([f"{path}: a non-Swift file in the UI tests"], tree)
            if name not in tree.files:
                reasons.append(f"{path}: removed (nothing left to run for it)")
                continue
            own = set(by_file[name])
            users = users_of(name, tree)
            if not own and not users:
                return full_plan([f"{path}: a UI test helper with no user found"], tree)
            chosen |= own | users
            reasons.append(f"{path}: " + ", ".join(sorted(own | users)))
            continue
        hit = areas_of(path)
        if hit:
            areas.update(hit)
            for a in hit:
                chosen |= area_classes(a, every)
            reasons.append(f"{path}: area {', '.join(hit)}")
        else:
            reasons.append(f"{path}: in no area (smoke; the nightly runs the rest)")
    if not ui:
        return Plan("none", reasons or ["no ios/** change"])
    smoke = {c for c in SMOKE if c in every}
    picked = {c: every[c] for c in sorted(chosen | smoke) if c in every}
    if not chosen - smoke:
        plan = smoke_plan(reasons, tree)
        plan.areas = sorted(areas)
        return plan
    legs = math.ceil(sum(picked.values()) / TESTS_PER_LEG)
    if legs >= FULL_LEGS:
        return full_plan(reasons + [f"{len(picked)} classes, {sum(picked.values())} tests: as big as the full suite"],
                         tree)
    names = [f"SnappetUITests-targeted-{i}of{legs}" for i in range(1, legs + 1)]
    return Plan("targeted", reasons, areas, picked, list(zip(names, split(picked, legs))))


# ── checks ──────────────────────────────────────────────────────────────────────────────────────────────────────────


def coverage_problems(tree=None):
    """Classes in no area and not in the smoke set; area / smoke patterns that match nothing."""
    tree = tree or Tree()
    every = tree.classes()
    problems = []
    placed = {c for a in AREAS for c in area_classes(a, every)} | set(SMOKE)
    for c in sorted(every):
        if c not in placed:
            problems.append(f"UI test class {c} is in no area and not in the smoke set (add it to AREAS)")
    for c in SMOKE:
        if c not in every:
            problems.append(f"smoke class {c} does not exist")
    for a, spec in AREAS.items():
        for pat in spec["classes"]:
            if not any(fnmatch.fnmatchcase(c, pat) for c in every):
                problems.append(f"area {a}: class pattern {pat} matches no UI test class")
    return problems


def path_problems():
    """Area path patterns that match no file in the repo (a folder was renamed)."""
    files = [p.relative_to(REPO).as_posix() for p in (REPO / "ios").rglob("*") if p.is_file()]
    problems = []
    for a, spec in AREAS.items():
        for pat in spec["paths"]:
            if not any(fnmatch.fnmatchcase(f, pat) for f in files):
                problems.append(f"area {a}: path pattern {pat} matches no file")
    return problems


def workflow_problems():
    """The `app` matrix fallback in ci.yml must be the full matrix."""
    try:
        text = WORKFLOW.read_text(encoding="utf-8")
    except OSError as e:
        return [f"cannot read {WORKFLOW}: {e}"]
    m = re.search(r"fromJSON\(needs\.changes\.outputs\.matrix \|\| '(\[.*?\])'\)", text)
    if not m:
        return ["ci.yml: no `fromJSON(needs.changes.outputs.matrix || '[…]')` fallback found"]
    want = [{"suite": "SnappetTests"}] + [{"suite": f"SnappetUITests-{i}of{FULL_LEGS}"} for i in range(1, FULL_LEGS + 1)]
    if json.loads(m.group(1)) != want:
        return [f"ci.yml: the matrix fallback is not the full matrix: {json.dumps(want, separators=(',', ':'))}"]
    return []


# ── CLI ─────────────────────────────────────────────────────────────────────────────────────────────────────────────


def _read_paths(arg):
    text = sys.stdin.read() if arg == "-" else pathlib.Path(arg).read_text(encoding="utf-8")
    return text.splitlines()


def _print_plan(plan):
    print(f"mode: {plan.mode}")
    for r in plan.reasons:
        print(f"  {r}")
    if plan.areas:
        print(f"areas: {', '.join(plan.areas)}")
    if plan.legs:
        print(f"{len(plan.classes)} classes, {sum(plan.classes.values())} tests, {len(plan.legs)} legs")
        for suite, members in plan.legs:
            print(f"{suite}: {sum(n for _, n in members)} tests, {len(members)} classes")
            print("  " + " ".join(f"{c}({n})" for c, n in members))
    print("matrix: " + json.dumps(plan.matrix(), separators=(",", ":")))


def main(argv):
    args = argv[1:]
    if args[:1] == ["--plan"] and len(args) == 2:
        count = int(args[1])
        for i, s in enumerate(shards(count), 1):
            print(f"shard {i}/{count}: {sum(n for _, n in s)} tests, {len(s)} classes")
            for name, n in s:
                print(f"  {name} ({n})")
        return 0
    if args[:1] == ["--check"] and len(args) <= 2:
        count = int(args[1]) if len(args) == 2 else FULL_LEGS
        plan = shards(count)
        placed = [name for s in plan for name, _ in s]
        every = classes()
        ok = sorted(placed) == sorted(every) and len(placed) == len(set(placed)) and all(plan)
        print(f"{len(every)} classes, {sum(every.values())} tests, {count} shards: {'ok' if ok else 'NOT ok'}")
        problems = [f"async in a UI test (a failure there is never retried; use setUpWithError / tearDownWithError): {h}"
                    for h in async_hooks()]
        problems += coverage_problems() + path_problems() + workflow_problems()
        for p in problems:
            print(p)
        return 0 if ok and not problems else 1
    if args[:1] == ["--select"] and len(args) in (2, 3) and args[2:] in ([], ["--push"]):
        _print_plan(select(_read_paths(args[1]), push="--push" in args))
        return 0
    if args[:1] == ["--matrix"]:
        if args[1:] == ["--full"]:
            plan = full_plan(["full"])
        elif args[1:] == ["--smoke"]:
            plan = smoke_plan(["smoke"])
        elif len(args) == 3 and args[1] == "--classes":
            try:
                plan = picked_plan(args[2])
            except ValueError as e:   # deliberately NOT fail-open
                print(f"::error title=ui_classes::{e}", file=sys.stderr)
                return 2
        elif len(args) >= 2 and not args[1].startswith("--"):
            rest = args[2:]
            push = "--push" in rest
            if push:
                rest.remove("--push")
            opts = dict(zip(rest[::2], rest[1::2]))
            fallback = opts.pop("--fallback", "full")
            labels = opts.pop("--labels", "")
            if len(rest) % 2 or opts or fallback not in ("full", "smoke"):
                print(__doc__, file=sys.stderr)
                return 2
            try:
                plan = label_plan(labels) or select(_read_paths(args[1]), push=push)
            except Exception as e:   # fail open: never run less than the fallback because of an error here
                print(f"::warning title=UI selection failed::{type(e).__name__}: {e}; running {fallback}",
                      file=sys.stderr)
                plan = full_plan([str(e)]) if fallback == "full" else smoke_plan([str(e)])
        else:
            print(__doc__, file=sys.stderr)
            return 2
        for r in plan.reasons:
            print(f"{plan.mode}: {r}", file=sys.stderr)
        print(json.dumps(plan.matrix(), separators=(",", ":")))
        return 0
    if args[:1] == ["--only"] and len(args) == 2:
        every = classes()
        names = args[1].split()
        unknown = [n for n in names if n not in every]
        if not names or unknown:
            print(f"no such UI test class: {' '.join(unknown) or '(none given)'}", file=sys.stderr)
            return 2
        for n in names:
            print(f"-only-testing:SnappetUITests/{n}")
        return 0
    if args == ["--areas"]:
        every = classes()
        for a, spec in AREAS.items():
            mine = sorted(area_classes(a, every))
            print(f"{a}: {len(mine)} classes, {sum(every[c] for c in mine)} tests")
            print(f"  paths: {' '.join(spec['paths'])}" + (f"  (not {' '.join(spec['not'])})" if spec.get("not") else ""))
            print(f"  {' '.join(f'{c}({every[c]})' for c in mine)}")
        smoke = [c for c in SMOKE if c in every]
        print(f"smoke: {len(smoke)} classes, {sum(every[c] for c in smoke)} tests: {' '.join(smoke)}")
        return 0
    if len(args) == 2 and all(a.isdigit() for a in args):
        index, count = int(args[0]), int(args[1])
        if not 1 <= index <= count:
            print(f"index {index} is outside 1…{count}", file=sys.stderr)
            return 2
        mine = shards(count)[index - 1]
        if not mine:
            print(f"shard {index}/{count} is empty", file=sys.stderr)
            return 2
        for name, _ in mine:
            print(f"-only-testing:SnappetUITests/{name}")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
