"""Tests for scripts/ci-ui-shard.py's UI test selection (prompt 268). Plain unittest, no dependencies:

    python3 -m unittest discover -s scripts -p 'test_ci_ui_shard.py' -v

They run against the real UI test sources, so they assert properties (which classes, how many legs, which mode)
rather than exact leg contents that move whenever a test is added.
"""
import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location("ci_ui_shard", pathlib.Path(__file__).with_name("ci-ui-shard.py"))
shard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shard)

UI = "ios/App/SnappetUITests/"
WT = "ios/App/Snappet/Features/WorkoutTracker/"


class SelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tree = shard.Tree()
        cls.every = cls.tree.classes()
        cls.smoke = set(shard.SMOKE)

    def select(self, *paths, push=False):
        return shard.select(list(paths), push=push, tree=self.tree)

    def leg_classes(self, plan):
        return [c for _, members in plan.legs for c, _ in members]

    def assertWellFormed(self, plan):
        placed = self.leg_classes(plan)
        self.assertEqual(len(placed), len(set(placed)), "a class is in two legs")
        self.assertEqual(set(placed), set(plan.classes))
        self.assertTrue(all(members for _, members in plan.legs), "an empty leg")
        self.assertLessEqual(len(plan.legs), shard.FULL_LEGS)

    def test_docs_only_runs_no_ui(self):
        plan = self.select("README.md", "pdd/context/decisions.md", "docs/knowledge-graph/data.js")
        self.assertEqual(plan.mode, "none")
        self.assertEqual(plan.matrix(), [{"suite": "SnappetTests"}])

    def test_unit_tests_and_ios_docs_run_no_ui(self):
        plan = self.select(f"ios/App/SnappetTests/RacketPlayerWatchTests.swift", "ios/HighlightEngine/Tests/X/Y.swift",
                           "ios/App/RUNBOOK-device.md")
        self.assertEqual(plan.mode, "none")

    def test_racket_only_runs_racket_classes_and_smoke(self):
        plan = self.select(WT + "RacketPlayerWatch.swift")
        self.assertEqual(plan.mode, "targeted")
        self.assertEqual(plan.areas, ["racket"])
        racket = {c for c in self.every if c.startswith("Racket")}
        self.assertTrue(racket <= set(plan.classes))
        self.assertTrue(self.smoke <= set(plan.classes))
        self.assertNotIn("KilterUITests", plan.classes)
        self.assertNotIn("FestivalUITests", plan.classes)
        self.assertGreater(len(plan.legs), 1)
        self.assertTrue(all(s.startswith("SnappetUITests-targeted-") for s, _ in plan.legs))
        self.assertWellFormed(plan)

    def test_workout_file_is_not_racket(self):
        plan = self.select(WT + "SessionDetailView.swift")
        self.assertEqual(plan.areas, ["workout"])
        self.assertIn("WorkoutBrokenLinksUITests", plan.classes)
        self.assertNotIn("RacketTaggingUITests", plan.classes)

    def test_shared_core_only_runs_smoke(self):
        for path in ("ios/App/Snappet/Core/AppModel.swift", "ios/App/project.yml", "ios/App/Shared/HeartRateZone.swift",
                     "ios/HighlightEngine/Sources/HighlightEngine/HighlightEngine.swift"):
            plan = self.select(path)
            self.assertEqual(plan.mode, "smoke", path)
            self.assertEqual(set(plan.classes), self.smoke)
            self.assertEqual([s for s, _ in plan.legs], ["SnappetUITests-smoke"])
            self.assertEqual(plan.matrix()[1]["classes"].split(), sorted(self.smoke))

    def test_ui_test_file_runs_its_class(self):
        plan = self.select(UI + "KilterStatsTests.swift")
        self.assertEqual(set(plan.classes), {"KilterStatsTests"} | self.smoke)
        self.assertEqual([s for s, _ in plan.legs], ["SnappetUITests-targeted-1of1"])

    def test_helper_file_runs_the_classes_that_use_it(self):
        plan = self.select(UI + "RacketPlayerControls.swift")
        self.assertEqual(set(plan.classes) - self.smoke,
                         {"RacketPlayerUITests", "RacketEditUITests", "RacketVideosUITests"})

    def test_extension_helper_is_matched_by_call_shape(self):
        # UITestTaps' `tap(_:until:)` must not match every `.tap()` in the suite.
        users = shard.users_of("UITestTaps.swift", self.tree)
        self.assertIn("RacketDrillUITests", users)          # startQuickSession()
        self.assertNotIn("FestivalUITests", users)          # only .tap()
        self.assertLess(len(users), 10)

    def test_helper_everyone_uses_runs_the_full_suite(self):
        plan = self.select(UI + "TestStoreGuard.swift")
        self.assertEqual(plan.mode, "full")

    def test_removed_ui_test_file_runs_smoke(self):
        plan = self.select(UI + "NoSuchTests.swift")
        self.assertEqual(plan.mode, "smoke")

    def test_unknown_helper_runs_the_full_suite(self):
        tree = shard.Tree({**self.tree.files, "Lonely.swift": "import XCTest\nprivate func nobodyCallsMe() {}\n"})
        self.assertEqual(shard.select([UI + "Lonely.swift"], tree=tree).mode, "full")

    def test_ci_yml_change_runs_the_full_suite(self):
        for path in shard.RECIPE:
            plan = self.select(path, "README.md")
            self.assertEqual(plan.mode, "full", path)
            self.assertEqual([r["suite"] for r in plan.matrix()],
                             ["SnappetTests"] + [f"SnappetUITests-{i}of8" for i in range(1, 9)])
            self.assertTrue(all("classes" not in r for r in plan.matrix()))

    def test_ci_yml_on_a_push_is_smoke(self):
        self.assertEqual(self.select(".github/workflows/ci.yml", push=True).mode, "smoke")
        self.assertEqual(self.select("README.md", push=True).mode, "none")

    def test_mixed_areas_beyond_one_leg(self):
        plan = self.select(WT + "RacketMatchFlow.swift", "ios/App/Snappet/Features/Festival/FestivalModels.swift",
                           "ios/App/Snappet/Features/Kilter/KilterView.swift", "ios/App/Snappet/Core/AppModel.swift")
        self.assertEqual(plan.mode, "targeted")
        self.assertEqual(plan.areas, ["festival", "kilter", "racket"])
        tests = sum(plan.classes.values())
        self.assertEqual(len(plan.legs), -(-tests // shard.TESTS_PER_LEG))
        self.assertGreater(len(plan.legs), 1)
        self.assertWellFormed(plan)
        self.assertEqual([s for s, _ in plan.legs],
                         [f"SnappetUITests-targeted-{i}of{len(plan.legs)}" for i in range(1, len(plan.legs) + 1)])
        loads = [sum(n for _, n in m) for _, m in plan.legs]
        self.assertLessEqual(max(loads) - min(loads), max(self.every.values()))   # balanced

    def test_selection_as_big_as_the_suite_runs_the_full_suite(self):
        paths = [p for a in shard.AREAS.values() for p in a["paths"]]
        concrete = [p.replace("*", "X.swift") for p in paths]
        self.assertEqual(self.select(*concrete).mode, "full")

    def test_empty_list_is_an_error_and_the_matrix_falls_back(self):
        with self.assertRaises(ValueError):
            self.select()
        for fallback, mode_suite in (("full", "SnappetUITests-1of8"), ("smoke", "SnappetUITests-smoke")):
            with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(shard.main(["x", "--matrix", f.name, "--fallback", fallback]), 0)
                self.assertIn(mode_suite, [r["suite"] for r in json.loads(out.getvalue())])

    def matrix_cli(self, *args, paths=()):
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
            f.write("\n".join(paths))
            f.flush()
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = shard.main(["x", "--matrix", f.name, *args])
            return code, (json.loads(out.getvalue()) if code == 0 else None)

    def test_ui_quick_label_beats_the_recipe_rule(self):
        # PR #457's shape: ci.yml + the script + many UI test files → smoke only with ui-quick.
        paths = [".github/workflows/ci.yml", "scripts/ci-ui-shard.py", UI + "RacketSportsUITests.swift"]
        code, matrix = self.matrix_cli("--labels", "documentation,ui-quick", paths=paths)
        self.assertEqual(code, 0)
        self.assertEqual([r["suite"] for r in matrix], ["SnappetTests", "SnappetUITests-smoke"])
        self.assertEqual(matrix[1]["classes"].split(), sorted(self.smoke))

    def test_full_ui_label_wins_over_ui_quick(self):
        code, matrix = self.matrix_cli("--labels", "ui-quick,full-ui", paths=["README.md"])
        self.assertEqual(len(matrix), 1 + shard.FULL_LEGS)
        self.assertEqual(shard.label_plan(["full-ui", "ui-quick"], self.tree).mode, "full")

    def test_ui_quick_even_without_a_change_list(self):
        # The workflow writes an empty list when the diff fails: the label still decides before the fallback.
        code, matrix = self.matrix_cli("--labels", "ui-quick", paths=[])
        self.assertEqual([r["suite"] for r in matrix], ["SnappetTests", "SnappetUITests-smoke"])
        code, matrix = self.matrix_cli("--labels", "", paths=[])
        self.assertEqual(len(matrix), 1 + shard.FULL_LEGS)

    def test_other_labels_change_nothing(self):
        self.assertIsNone(shard.label_plan("bug,enhancement"))
        code, matrix = self.matrix_cli("--labels", "bug", paths=[WT + "RacketMatchFlow.swift"])
        self.assertTrue(matrix[1]["suite"].startswith("SnappetUITests-targeted-"))

    def test_dispatch_ui_classes_runs_exactly_those(self):
        plan = shard.picked_plan("RacketPlayerUITests, RacketEditUITests", self.tree)
        self.assertEqual(set(plan.classes), {"RacketPlayerUITests", "RacketEditUITests"})   # no smoke added
        self.assertEqual([s for s, _ in plan.legs], ["SnappetUITests-picked-1of1"])
        big = shard.picked_plan(",".join(c for c in self.every if c.startswith("Racket")), self.tree)
        self.assertEqual(len(big.legs), -(-sum(big.classes.values()) // shard.TESTS_PER_LEG))
        self.assertWellFormed(big)

    def test_dispatch_unknown_class_fails_and_does_not_fall_back(self):
        with self.assertRaises(ValueError):
            shard.picked_plan("RacketPlayerUITests,RacketPlayerUITest", self.tree)
        with self.assertRaises(ValueError):
            shard.picked_plan(" , ", self.tree)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(shard.main(["x", "--matrix", "--classes", "NoSuchTests"]), 2)
        self.assertEqual(out.getvalue(), "")   # no matrix printed at all

    def test_matrix_rows_round_trip_through_only(self):
        plan = self.select(WT + "RacketMatchFlow.swift")
        for row in plan.matrix()[1:]:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(shard.main(["x", "--only", row["classes"]]), 0)
            self.assertEqual(out.getvalue().split(),
                             [f"-only-testing:SnappetUITests/{c}" for c in row["classes"].split()])

    def test_only_rejects_unknown_classes(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(shard.main(["x", "--only", "SuiteSmokeTests NoSuchClass"]), 2)
            self.assertEqual(shard.main(["x", "--only", ""]), 2)


class CheckTests(unittest.TestCase):
    def test_the_real_tree_is_covered(self):
        self.assertEqual(shard.coverage_problems(), [])
        self.assertEqual(shard.path_problems(), [])
        self.assertEqual(shard.workflow_problems(), [])
        self.assertEqual(shard.async_hooks(), [])

    def test_a_class_in_no_area_fails_the_check(self):
        tree = shard.Tree({**shard.Tree().files,
                           "ZebraTests.swift": "final class ZebraTests: XCTestCase {\n    func testA() {}\n}\n"})
        self.assertTrue(any("ZebraTests" in p for p in shard.coverage_problems(tree)))

    def test_an_area_pattern_matching_nothing_fails_the_check(self):
        files = {k: v for k, v in shard.Tree().files.items() if k != "FestivalUITests.swift"}
        self.assertTrue(any("FestivalUITests" in p for p in shard.coverage_problems(shard.Tree(files))))

    def test_full_shards_place_every_class_once(self):
        every = shard.classes()
        placed = [c for s in shard.shards(shard.FULL_LEGS) for c, _ in s]
        self.assertEqual(sorted(placed), sorted(every))


if __name__ == "__main__":
    unittest.main()
