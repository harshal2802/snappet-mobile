#!/usr/bin/env python3
"""Split the SnappetUITests classes into N balanced shards for CI (prompt 261).

    scripts/ci-ui-shard.py <index> <count>     # prints one `-only-testing:SnappetUITests/<Class>` per line
    scripts/ci-ui-shard.py --plan <count>      # prints every shard with its classes and test counts
    scripts/ci-ui-shard.py --check <count>     # exits 1 unless every test class is in exactly one shard and no UI
                                               # test has an async setUp / tearDown / test (they are never retried)

Classes are found by reading the sources (no build needed): each `class X: XCTestCase` with at least one
`func test…`. A class is weighted by its number of tests and placed, heaviest first, on the lightest shard so
far (ties: lowest shard, then class name), so the split is the same on every machine and a new test class
lands in a shard without anyone editing a list.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "ios" / "App" / "SnappetUITests"
CLASS = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+)?(?:final\s+)?class\s+(\w+)\s*:\s*[^{]*\bXCTestCase\b")
TEST = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+)?func\s+test\w*\s*\(")
# An async setUp / tearDown / test in a UI test class: when it fails with `continueAfterFailure = false`, the test
# runner exits and xcodebuild restarts it at the NEXT test, so `-retry-tests-on-failure` never retries it (prompt 267).
ASYNC = re.compile(r"\bfunc\s+(setUp|tearDown|test\w*)\s*\([^)]*\)\s*async\b")


def classes():
    """{class name: number of test methods}, for classes that have tests."""
    found = {}
    for path in sorted(ROOT.rglob("*.swift")):
        current = None
        for line in path.read_text(encoding="utf-8").splitlines():
            m = CLASS.match(line)
            if m:
                current = m.group(1)
                found.setdefault(current, 0)
            elif current and TEST.match(line):
                found[current] += 1
    return {name: n for name, n in found.items() if n > 0}


def async_hooks():
    """["File.swift:line: text"] for every async setUp / tearDown / test in the UI tests."""
    found = []
    for path in sorted(ROOT.rglob("*.swift")):
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if ASYNC.search(line):
                found.append(f"{path.name}:{n}: {line.strip()}")
    return found


def shards(count):
    out = [[] for _ in range(count)]
    load = [0] * count
    for name, n in sorted(classes().items(), key=lambda kv: (-kv[1], kv[0])):
        i = min(range(count), key=lambda k: (load[k], k))
        out[i].append((name, n))
        load[i] += n
    return [sorted(s) for s in out]


def main(argv):
    if len(argv) == 3 and argv[1] in ("--plan", "--check"):
        count = int(argv[2])
        plan = shards(count)
        if argv[1] == "--plan":
            for i, s in enumerate(plan, 1):
                print(f"shard {i}/{count}: {sum(n for _, n in s)} tests, {len(s)} classes")
                for name, n in s:
                    print(f"  {name} ({n})")
            return 0
        placed = [name for s in plan for name, _ in s]
        every = classes()
        ok = sorted(placed) == sorted(every) and len(placed) == len(set(placed)) and all(plan)
        print(f"{len(every)} classes, {sum(every.values())} tests, {count} shards: {'ok' if ok else 'NOT ok'}")
        hooks = async_hooks()
        for h in hooks:
            print(f"async in a UI test (a failure there is never retried; use setUpWithError / tearDownWithError): {h}")
        return 0 if ok and not hooks else 1
    if len(argv) == 3:
        index, count = int(argv[1]), int(argv[2])
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
