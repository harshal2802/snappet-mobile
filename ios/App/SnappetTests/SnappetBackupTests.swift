import XCTest
import CoreGraphics
import SwiftData
@testable import Snappet

/// Locks the #68 backup contract: ONE versioned JSON file round-trips **every**
/// `SnappetSchema` model field-for-field (incl. workout/Kilter HR series and Studio
/// projects with their FKs), restore is replace-everything, wrong/garbage files are
/// rejected before anything is touched, and the codec can't silently drift from the
/// schema. Runs against in-memory `ModelContainer`s — no UI, no device.
@MainActor
final class SnappetBackupTests: XCTestCase {

    /// Held as properties: a `ModelContext` does NOT retain its `ModelContainer`; letting
    /// the container deallocate makes every later SwiftData call trap (EXC_BREAKPOINT).
    private var sourceContainer: ModelContainer!
    private var targetContainer: ModelContainer!

    override func setUpWithError() throws {
        sourceContainer = try makeContainer()
        targetContainer = try makeContainer()
    }

    override func tearDown() {
        sourceContainer = nil
        targetContainer = nil
        super.tearDown()
    }

    // nonisolated: called from setUpWithError, whose XCTest override is nonisolated even in a
    // @MainActor class — a MainActor-isolated helper there is a Swift 6 "sending self" error.
    private nonisolated func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    // MARK: - Drift tripwire

    /// Every model in `SnappetSchema.models` must have a Row in the codec (and vice versa).
    /// If this fails you added/removed a `@Model` without updating `SnappetBackup`.
    func testCodecCoversEverySchemaModel() {
        let schema = Set(SnappetSchema.models.map { ObjectIdentifier($0) })
        let covered = Set(SnappetBackup.coveredModels.map { ObjectIdentifier($0) })
        XCTAssertEqual(schema, covered,
                       "SnappetBackup must cover exactly the SnappetSchema models — add the missing Row")
        XCTAssertEqual(SnappetBackup.coveredModels.count, SnappetSchema.models.count)
    }

    /// Store-side row count for one covered model (generic so the `coveredModels`
    /// existential opens implicitly).
    private func count<M: PersistentModel>(of type: M.Type, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<M>())
    }

    /// Total rows across every covered model, counted straight off the store — the
    /// independent twin of `File.recordCount` (which hand-sums the per-model arrays).
    /// A model wired into the schema + `coveredModels` but NOT into the File/snapshot/
    /// restore plumbing makes the two disagree, so the half-covered drift the tripwire
    /// above can't see fails here instead of silently dropping data.
    private func storeRecordCount(in context: ModelContext) throws -> Int {
        var total = 0
        for model in SnappetBackup.coveredModels {
            total += try count(of: model, in: context)
        }
        return total
    }

    // MARK: - Full round trip

    /// Seed one richly-populated instance of every model, export, restore onto a FRESH
    /// store, and verify the re-snapshot is identical row-for-row (which covers every
    /// field, every nested composite, every Date — bit-exact, since rows are Hashable).
    func testRoundTripPreservesEveryModelOnAFreshStore() throws {
        let context = sourceContainer.mainContext
        seedEveryModel(into: context)
        try context.save()

        // Every covered model must be EXERCISED here: a covered model seeded with zero
        // rows would let one missing from File/snapshot/restore pass this round trip
        // while a real restore wiped its rows without re-inserting (#68 review fix 5).
        for model in SnappetBackup.coveredModels {
            XCTAssertGreaterThanOrEqual(try count(of: model, in: context), 1,
                                        "seedEveryModel must seed at least one \(model)")
        }

        let exported = try SnappetBackup.snapshot(of: context)
        XCTAssertEqual(exported.recordCount, 36, "every seeded row is captured")
        XCTAssertEqual(exported.recordCount, try storeRecordCount(in: context),
                       "File.recordCount must match the store's fetchCount total — a "
                       + "half-wired model makes these disagree")
        let data = try SnappetBackup.encode(exported)

        let decoded = try SnappetBackup.decode(data)
        XCTAssertEqual(decoded, exported, "encode→decode is lossless (incl. exact Dates)")

        let target = targetContainer.mainContext
        try SnappetBackup.restore(decoded, into: target)
        XCTAssertEqual(try storeRecordCount(in: target), exported.recordCount,
                       "restore re-inserts every covered model's rows")
        var reSnapshot = try SnappetBackup.snapshot(of: target)
        // exportedAt is provenance, not data — align it before comparing the payload.
        reSnapshot.exportedAt = exported.exportedAt
        XCTAssertEqual(reSnapshot, exported, "restore reproduces every row on a fresh store")
    }

    /// The flagship fidelity cases called out by the issue: a workout's full HR series
    /// (with RR intervals) and a Studio project's timeline/overlay/FK graph.
    func testHRSeriesAndStudioProjectSurviveExactly() throws {
        let context = sourceContainer.mainContext
        let session = makeWorkoutSession()
        let project = makeStudioProject(sessionID: session.id)
        context.insert(session)
        context.insert(project)
        try context.save()

        let data = try SnappetBackup.encode(try SnappetBackup.snapshot(of: context))
        let target = targetContainer.mainContext
        try SnappetBackup.restore(try SnappetBackup.decode(data), into: target)

        let restoredSession = try XCTUnwrap(
            try target.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(restoredSession.id, session.id)
        XCTAssertEqual(restoredSession.hrSeries.count, 3600)
        XCTAssertEqual(restoredSession.hrSeries, session.hrSeries, "HR series is bit-exact")
        XCTAssertEqual(restoredSession.hrSeries[10].rrIntervalsMs, [812.5, 798.25])
        XCTAssertEqual(restoredSession.exercises, session.exercises)

        let restoredProject = try XCTUnwrap(
            try target.fetch(FetchDescriptor<StudioProject>()).first)
        XCTAssertEqual(restoredProject.sessionID, session.id, "FK to the session survives")
        XCTAssertEqual(restoredProject.clips, project.clips)
        XCTAssertEqual(restoredProject.overlays, project.overlays)
        XCTAssertEqual(restoredProject.transitions, project.transitions)
        XCTAssertEqual(restoredProject.audioTracks, project.audioTracks)
        XCTAssertEqual(restoredProject.baseFrame, project.baseFrame)
        XCTAssertEqual(restoredProject.hrOverlay, project.hrOverlay)
        XCTAssertEqual(restoredProject.updatedAt, project.updatedAt,
                       "updatedAt restores verbatim (the init would pin it to createdAt)")
    }

    // MARK: - Replace-everything semantics

    /// Restore wipes what's in the store first — including rows whose unique keys overlap
    /// the incoming ones (`KilterFavorite.climbUUID`, `KilterSession.id`) — and ends with
    /// exactly the backup's contents.
    func testRestoreReplacesExistingDataIncludingUniqueKeyOverlap() throws {
        // The backup: one favorite + one session.
        let source = sourceContainer.mainContext
        let keptSessionID = UUID()
        source.insert(KilterFavorite(climbUUID: "shared-climb", addedAt: Date(timeIntervalSince1970: 100)))
        source.insert(KilterSession(id: keptSessionID, angle: 40, source: "manual"))
        try source.save()
        let file = try SnappetBackup.snapshot(of: source)

        // The device being restored: stale rows, one sharing the favorite's unique key.
        let target = targetContainer.mainContext
        target.insert(KilterFavorite(climbUUID: "shared-climb", addedAt: Date(timeIntervalSince1970: 999)))
        target.insert(KilterFavorite(climbUUID: "doomed-climb"))
        target.insert(JournalEntry(title: "Doomed", body: "Replaced by restore"))
        target.insert(KilterSession(id: keptSessionID, angle: 70, source: "ble"))
        try target.save()

        try SnappetBackup.restore(file, into: target)

        let favorites = try target.fetch(FetchDescriptor<KilterFavorite>())
        XCTAssertEqual(favorites.map(\.climbUUID), ["shared-climb"])
        XCTAssertEqual(favorites.first?.addedAt, Date(timeIntervalSince1970: 100),
                       "the backup's row wins, not the stale one")
        XCTAssertEqual(try target.fetch(FetchDescriptor<JournalEntry>()).count, 0)
        let sessions = try target.fetch(FetchDescriptor<KilterSession>())
        XCTAssertEqual(sessions.map(\.angle), [40])
    }

    // MARK: - Duplicate-id rows (a tampered/duplicated file is legal JSON)

    /// Duplicate-id rows decode fine (nothing in the JSON forbids them) but must never
    /// enter the store, where they'd corrupt FK joins and crash id-keyed lookups —
    /// restore dedupes FIRST-WINS per identity key (#68 review fix 4).
    func testRestoreDeduplicatesDuplicateIDRowsFirstWins() throws {
        var file = SnappetBackup.File()
        let habitID = UUID()
        file.habits = [
            SnappetBackup.HabitRow(Habit(id: habitID, name: "First wins", symbol: "drop",
                                         createdAt: Date(timeIntervalSince1970: 1))),
            SnappetBackup.HabitRow(Habit(id: habitID, name: "Duplicate", symbol: "flame",
                                         createdAt: Date(timeIntervalSince1970: 2))),
        ]
        let sessionID = UUID()
        file.kilterSessions = [
            SnappetBackup.KilterSessionRow(KilterSession(id: sessionID, angle: 40, source: "manual")),
            SnappetBackup.KilterSessionRow(KilterSession(id: sessionID, angle: 70, source: "ble")),
        ]
        file.kilterFavorites = [
            SnappetBackup.KilterFavoriteRow(KilterFavorite(climbUUID: "dup-climb",
                                                           addedAt: Date(timeIntervalSince1970: 100))),
            SnappetBackup.KilterFavoriteRow(KilterFavorite(climbUUID: "dup-climb",
                                                           addedAt: Date(timeIntervalSince1970: 999))),
        ]
        XCTAssertEqual(file.recordCount, 6, "the duplicates are legal file contents")

        let target = targetContainer.mainContext
        try SnappetBackup.restore(file, into: target)

        let habits = try target.fetch(FetchDescriptor<Habit>())
        XCTAssertEqual(habits.map(\.name), ["First wins"], "one row per id, first occurrence wins")
        let sessions = try target.fetch(FetchDescriptor<KilterSession>())
        XCTAssertEqual(sessions.map(\.angle), [40])
        let favorites = try target.fetch(FetchDescriptor<KilterFavorite>())
        XCTAssertEqual(favorites.map(\.addedAt), [Date(timeIntervalSince1970: 100)])
    }

    // MARK: - Live @Model holders detach before restore

    /// `KilterSessionManager.detachForStoreRestore()` (the AppModel-owned holder of a live
    /// `KilterSession`) drops the in-memory session WITHOUT writing to the store — the
    /// restore deletes the rows anyway — and `recover(in:)` re-adopts whatever open
    /// session the restored data carries (#68 review fix 2, the #54 recovery semantics).
    func testDetachForStoreRestoreDropsLiveSessionWithoutWritingThenRecoverReAdopts() throws {
        let context = sourceContainer.mainContext
        let manager = KilterSessionManager()
        manager.start(angle: 40, source: "manual", in: context)
        let liveID = try XCTUnwrap(manager.currentId)
        manager.beginClimb(uuid: "c1", name: "Crimpy", grade: "6a/V3")

        manager.detachForStoreRestore()
        XCTAssertFalse(manager.isActive, "the live reference is dropped")
        XCTAssertNil(manager.activeClimbUUID, "active-climb state is cleared")
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<KilterSession>()).first)
        XCTAssertEqual(stored.id, liveID)
        XCTAssertNil(stored.endedAt, "detach writes NOTHING — the row stays open for deletion")

        // The backup being restored carries its own open session; restore + recover adopt it.
        let restoredOpenID = UUID()
        var file = SnappetBackup.File()
        file.kilterSessions = [
            SnappetBackup.KilterSessionRow(KilterSession(id: restoredOpenID, angle: 45, source: "ble")),
        ]
        try SnappetBackup.restore(file, into: context)
        manager.recover(in: context)
        XCTAssertEqual(manager.currentId, restoredOpenID,
                       "recover re-adopts the restored open session, not the deleted one")
    }

    // MARK: - Rejection (strict, validate-before-touch)

    func testDecodeRejectsGarbageForeignAndWrongVersionFiles() {
        XCTAssertThrowsError(try SnappetBackup.decode(Data("not json at all".utf8))) {
            XCTAssertEqual($0 as? SnappetBackupError, .notABackup)
        }
        XCTAssertThrowsError(try SnappetBackup.decode(Data(#"{"some":"json"}"#.utf8))) {
            XCTAssertEqual($0 as? SnappetBackupError, .notABackup)
        }
        let wrongVersion = #"{"kind":"snappet.backup","formatVersion":2}"#
        XCTAssertThrowsError(try SnappetBackup.decode(Data(wrongVersion.utf8))) {
            XCTAssertEqual($0 as? SnappetBackupError, .unsupportedVersion(2))
        }
        let truncated = #"{"kind":"snappet.backup","formatVersion":1,"habits":[]}"#
        XCTAssertThrowsError(try SnappetBackup.decode(Data(truncated.utf8))) {
            XCTAssertEqual($0 as? SnappetBackupError, .damaged)
        }
    }

    /// A bad file never reaches `restore` (decode throws first), so existing data survives.
    func testRejectedFileLeavesStoreUntouched() throws {
        let target = targetContainer.mainContext
        target.insert(JournalEntry(title: "Keep me", body: "Still here"))
        try target.save()

        XCTAssertThrowsError(try SnappetBackup.decode(Data("junk".utf8)))

        let entries = try target.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(entries.map(\.title), ["Keep me"])
    }

    // MARK: - Determinism

    /// Two snapshots of the same store encode to the same bytes (stable row ordering +
    /// sorted keys) — backups are diffable and re-export equality is meaningful.
    func testSnapshotEncodingIsDeterministic() throws {
        let context = sourceContainer.mainContext
        seedEveryModel(into: context)
        try context.save()

        var a = try SnappetBackup.snapshot(of: context)
        var b = try SnappetBackup.snapshot(of: context)
        let stamp = Date(timeIntervalSinceReferenceDate: 1_000)
        a.exportedAt = stamp
        b.exportedAt = stamp
        XCTAssertEqual(try SnappetBackup.encode(a), try SnappetBackup.encode(b))
    }

    // MARK: - F4: KilterLitEvent sortKey is total/stable across same-climb/different-session

    /// Two `KilterLitEvent` rows for the SAME climb at the SAME instant + angle but DIFFERENT sessions must
    /// get DISTINCT sort keys, so the backup row ordering is total and the round-trip export is
    /// deterministic. The old key omitted `sessionId`, so cross-session rows tied — leaving their order to
    /// the (input-dependent) sort, which broke the re-export-equality contract (#68 determinism).
    func testKilterLitEventSortKeyDistinguishesSameClimbDifferentSession() {
        let at = Date(timeIntervalSince1970: 1_700_009_200)
        func row(_ session: UUID?, connected: Bool = true) -> SnappetBackup.KilterLitEventRow {
            SnappetBackup.KilterLitEventRow(
                KilterLitEvent(climbUUID: "abc", climbName: "Crimpy", gradeLabel: "6a/V3",
                               angle: 40, layoutId: 1, sizeId: 10, litAt: at,
                               wasConnected: connected, sessionId: session))
        }
        let s1 = row(UUID()), s2 = row(UUID())
        XCTAssertNotEqual(s1.sortKey, s2.sortKey,
                          "same climb/instant/angle in different sessions must not collide")
        // A nil-session row is distinct from a real-session one (its own bucket), and from a same-key row
        // that differs only in `wasConnected` (the final distinguishing field).
        XCTAssertNotEqual(row(nil).sortKey, s1.sortKey)
        let session = UUID()
        XCTAssertNotEqual(row(session, connected: true).sortKey,
                          row(session, connected: false).sortKey,
                          "wasConnected breaks an otherwise-identical key")
    }

    // MARK: - Seed helpers (rich field coverage, incl. raw strings outside the enums)

    /// One instance of every schema model — 23 rows total (two ExpenseRecords: an itemized
    /// receipt AND a settlement, the two shapes sharing that model).
    private func seedEveryModel(into context: ModelContext) {
        context.insert(UsageRecord(module: "journal", action: "entry", summary: "Wrote a note",
                                   metric: 2.5, timestamp: Date(timeIntervalSince1970: 1_700_000_000.125)))
        context.insert(PomodoroSession(minutes: 25, completedAt: Date(timeIntervalSince1970: 1_700_001_000)))

        let habit = Habit(name: "Hydrate", symbol: "drop")
        context.insert(habit)
        context.insert(HabitCompletion(habitID: habit.id, day: Date(timeIntervalSince1970: 1_700_002_000)))

        let entry = JournalEntry(title: "Trip", body: "Long day, good \"climbs\".\nNew line.",
                                 createdAt: Date(timeIntervalSince1970: 1_700_003_000),
                                 updatedAt: Date(timeIntervalSince1970: 1_700_003_600))
        entry.tags = ["Travel", "travel"]   // deliberately NOT normalized — must survive verbatim
        context.insert(entry)

        let group = ExpenseGroup(name: "Trip, 2026", participants: ["Ana", "Bo"])
        context.insert(group)
        context.insert(ExpenseRecord(groupID: group.id, title: "Groceries", amount: 33.5,
                                     payer: "Ana", participants: ["Ana", "Bo"],
                                     date: Date(timeIntervalSince1970: 1_700_004_000),
                                     items: [ReceiptItem(name: "Milk \"2%\"", price: 3.5, assignees: ["Bo"])],
                                     taxAmount: 2.5, discountAmount: 1.0))
        context.insert(ExpenseRecord(groupID: group.id, title: "Settle", amount: 12,
                                     payer: "Bo", participants: ["Ana"],
                                     date: Date(timeIntervalSince1970: 1_700_004_500),
                                     isSettlement: true))

        let category = BudgetCategory(name: "Food", monthlyLimit: 400)
        context.insert(category)
        context.insert(BudgetTransaction(categoryID: category.id, amount: 12.75,
                                         note: "Lunch, with a comma",
                                         date: Date(timeIntervalSince1970: 1_700_005_000)))

        let routine = Routine(name: "Push day",
                              exercises: [RoutineExercise(exerciseId: "bench-press", sets: 3,
                                                          reps: "8-12", restSeconds: 90,
                                                          weight: 60, weightUnit: .kg,
                                                          notes: "pause reps", displayName: "Bench")],
                              isStarter: true, starterKey: "starter-push",
                              tags: ["strength"], detail: "details",
                              sourceLabel: "src", sourceURL: "https://example.com")
        routine.sportRaw = "futuresport"   // unknown raw value — must survive verbatim
        routine.levelRaw = "intermediate"
        context.insert(routine)

        let session = makeWorkoutSession(routineID: routine.id)
        context.insert(session)

        let custom = CustomExercise(name: "Campus pulls", instructions: ["hang", "pull"])
        custom.forceRaw = "pull"
        custom.primaryMuscles = ["forearms"]
        context.insert(custom)

        let media = SessionMedia(sessionID: session.id, localIdentifier: "PHAsset-123",
                                 kind: .video, offsetSec: 12.5, durationSec: 9.5,
                                 addedManually: true,
                                 assignedExerciseID: session.exercises.first?.id,
                                 assignedSetIndex: 1,
                                 assignedClimbUUID: "climb-uuid",
                                 source: .manual)
        context.insert(media)

        context.insert(TimedExerciseCatalog(name: "7s max hang", category: .hangboard,
                                            spec: .maxHang7,
                                            createdAt: Date(timeIntervalSince1970: 1_700_006_500),
                                            lastUsedAt: Date(timeIntervalSince1970: 1_700_006_800)))

        context.insert(makeStudioProject(sessionID: session.id))

        context.insert(TipCalculation(bill: 84.2, tipPct: 18.5, people: 3,
                                      tipAmount: 15.58, total: 99.78,
                                      date: Date(timeIntervalSince1970: 1_700_007_000)))

        let kilterSession = KilterSession(startedAt: Date(timeIntervalSince1970: 1_700_008_000),
                                          endedAt: Date(timeIntervalSince1970: 1_700_009_000),
                                          angle: 40, source: "ble",
                                          hrSeries: [HRPoint(t: 0, bpm: 110),
                                                     HRPoint(t: 1, bpm: 124, rrIntervalsMs: [488])],
                                          maxHR: 192, restHR: 52,
                                          metricsSourceRaw: "ble", kcalEstimate: 240.5,
                                          title: "Comp prep", notes: "Strong day; flashed warmups.",
                                          layoutId: 1)
        context.insert(kilterSession)

        let log = KilterLogEntry(climbUUID: "abc123", climbName: "Crimpy",
                                 angle: 40, difficulty: 16.4, gradeLabel: "6a/V3",
                                 status: .flash, attempts: 2,
                                 date: Date(timeIntervalSince1970: 1_700_009_500),
                                 sessionId: kilterSession.id,
                                 startedAt: Date(timeIntervalSince1970: 1_700_009_300),
                                 endedAt: Date(timeIntervalSince1970: 1_700_009_500),
                                 attemptTimestamps: [Date(timeIntervalSince1970: 1_700_009_350),
                                                     Date(timeIntervalSince1970: 1_700_009_450)],
                                 note: "felt easy")
        context.insert(log)

        context.insert(KilterFavorite(climbUUID: "abc123",
                                      addedAt: Date(timeIntervalSince1970: 1_700_010_000)))
        context.insert(KilterCreatedClimb(uuid: "created-uuid", name: "My line",
                                          setterUsername: "You", layoutId: 1, sizeId: 10,
                                          angle: 40, frames: "p1100r12p1200r14",
                                          edgeLeft: 4, edgeRight: 140, edgeBottom: 4, edgeTop: 152,
                                          isNoMatch: true, predictedGrade: 20.2,
                                          source: "generated", modelId: "model-q",
                                          createdAt: Date(timeIntervalSince1970: 1_700_011_000)))

        context.insert(KilterPlan(
            createdAt: Date(timeIntervalSince1970: 1_700_012_000), angle: 40, layoutId: 1,
            workingDifficulty: 18, workingGradeLabel: "6a/V3", title: "Volume night",
            sessionId: kilterSession.id, completedAt: Date(timeIntervalSince1970: 1_700_013_000),
            optionsTargetCount: 6, optionsSendThreshold: 2, optionsPreferUnsent: false,
            optionsGradeOffset: 1, strategyRaw: "volume",
            items: [
                KilterPlanItem(order: 0, goal: .warmup, climbUUID: "w-1", climbName: "Slab",
                               setter: "Tonde", gradeLabel: "5+/V2", difficulty: 16,
                               status: .sent, completedAt: Date(timeIntervalSince1970: 1_700_012_300)),
                KilterPlanItem(order: 1, goal: .send, climbUUID: "s-1", climbName: "Crimps",
                               setter: "Ana", gradeLabel: "6a/V3", difficulty: 18,
                               status: .attempted, locked: true,
                               completedAt: Date(timeIntervalSince1970: 1_700_012_600)),
                KilterPlanItem(order: 2, goal: .project, climbUUID: "p-1", climbName: "Arete",
                               setter: "Sven", gradeLabel: "6b/V4", difficulty: 20, status: .pending),
            ]))

        context.insert(KilterLitEvent(climbUUID: "abc123", climbName: "Crimpy", gradeLabel: "6a/V3",
                                      angle: 40, layoutId: 1, sizeId: 10,
                                      litAt: Date(timeIntervalSince1970: 1_700_009_200),
                                      wasConnected: true, sessionId: kilterSession.id))

        // Recap feed (F0b): append-only activity log + interaction rows + outbox.
        let feedContentId = FeedContentIdentity.kilterSession(id: kilterSession.id.uuidString)
        context.insert(FeedActivity(contentId: feedContentId, verb: "loggedSession",
                                    objectRef: kilterSession.id.uuidString, objectKind: "kilterSession",
                                    targetRef: "1", published: Date(timeIntervalSince1970: 1_700_009_300),
                                    foreignId: "loggedSession:\(feedContentId)",
                                    aggregationKey: "1:loggedSession:kilterSession:2026-06-20"))
        context.insert(FeedReaction(activityContentId: feedContentId, typeRaw: "note", value: "proud send",
                                    createdAt: Date(timeIntervalSince1970: 1_700_009_400)))
        context.insert(FeedSaveItem(activityContentId: feedContentId, collectionId: "proud-sends",
                                    createdAt: Date(timeIntervalSince1970: 1_700_009_500)))
        context.insert(FeedShareEvent(activityContentId: feedContentId, channel: "export:instagram",
                                      createdAt: Date(timeIntervalSince1970: 1_700_009_600)))
        context.insert(FeedOutboxEntry(activityContentId: feedContentId, opRaw: "create",
                                       createdAt: Date(timeIntervalSince1970: 1_700_009_700)))

        // Wardrobe: an item WITH image bytes (Data must survive the JSON round trip),
        // a wear event pointing at it, and a two-slot outfit.
        let wardrobeItem = WardrobeItem(name: "Navy flannel shirt", category: .top, color: .navy,
                                        pattern: .plaid, style: .casual, material: "Cotton flannel",
                                        seasons: [.fall, .winter], cost: 49, isFavorite: true,
                                        createdAt: Date(timeIntervalSince1970: 1_700_010_000),
                                        imageData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]))
        context.insert(wardrobeItem)
        // An EXTRA photo of that item (wardrobe prompt 04) — the cover itself rides the item above,
        // so this row is the "back of the shirt" case, with a non-default role and sortIndex.
        context.insert(WardrobePhoto(itemID: wardrobeItem.id, role: .back, sortIndex: 1,
                                     imageData: Data([0x89, 0x50, 0x4E, 0x47, 0x1A, 0x0B]),
                                     createdAt: Date(timeIntervalSince1970: 1_700_010_050)))
        let wardrobeOutfit = WardrobeOutfit(
            title: "Work · Cool", occasion: .work, tempBand: .cool, season: .fall,
            rationale: ["Oxford + chinos hits business casual."],
            slots: [.init(role: .top, itemID: wardrobeItem.id)],
            createdAt: Date(timeIntervalSince1970: 1_700_010_100),
            lastWornAt: Date(timeIntervalSince1970: 1_700_010_200))
        context.insert(wardrobeOutfit)
        context.insert(WearEvent(itemID: wardrobeItem.id, outfitID: wardrobeOutfit.id,
                                 wornOn: Date(timeIntervalSince1970: 1_700_010_200)))

        // Festival: an installed lineup WITH its .fpack bytes (Data must survive the JSON round
        // trip), a starred set, and a closed "I'm here" stretch pointing at a session.
        let festivalPack = FestivalFixtures.glastonbury()
        let festivalSet = FestivalFixtures.set(named: "Fred again..", in: festivalPack)
        context.insert(FestivalLineup(
            packID: festivalPack.id, name: festivalPack.name, location: festivalPack.location,
            startDate: festivalPack.startDate, endDate: festivalPack.endDate,
            utcOffsetSeconds: festivalPack.utcOffsetSeconds, stageCount: 6, setCount: 8,
            sourceLabel: "Snappet Lineups",
            installedAt: Date(timeIntervalSince1970: 1_700_011_000),
            fpackData: (try? festivalPack.fpackData()) ?? Data([0x46, 0x50, 0x41, 0x4B])))
        context.insert(FestivalStar(packID: festivalPack.id, setID: festivalSet.id,
                                    createdAt: Date(timeIntervalSince1970: 1_700_011_100)))
        context.insert(FestivalAttendance(
            packID: festivalPack.id, setID: festivalSet.id,
            artist: festivalSet.artist, stage: festivalSet.stage, sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_011_200),
            endedAt: Date(timeIntervalSince1970: 1_700_011_300)))
        context.insert(FestivalClipTag(
            packID: festivalPack.id, setID: festivalSet.id,
            artist: festivalSet.artist, stage: festivalSet.stage,
            mediaID: UUID(), sessionID: UUID(),
            confidence: 0.97, reason: "mid-set", source: .auto,
            createdAt: Date(timeIntervalSince1970: 1_700_011_400)))
    }

    /// An hour-long session at 1 Hz (3600 HR points, RR intervals on one sample) with a
    /// mixed-kind exercise list — the HR-fidelity and composite-survival case.
    private func makeWorkoutSession(routineID: UUID? = nil) -> WorkoutSession {
        var hr: [HRPoint] = (0..<3600).map { HRPoint(t: Double($0), bpm: 100 + 60 * sin(Double($0) / 300)) }
        hr[10].rrIntervalsMs = [812.5, 798.25]
        var exercise = SessionExercise(exerciseId: "bench-press", targetSets: 3, targetReps: "8",
                                       targetRestSeconds: 90, targetWeight: 60, targetWeightUnit: .kg,
                                       sets: [SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg,
                                                     completedAt: Date(timeIntervalSince1970: 1_700_005_500))],
                                       displayName: "Bench")
        exercise.kindRaw = SetKind.repsWeight.rawValue
        var climb = SessionExercise(exerciseId: "adhoc-climb", targetSets: 1, targetReps: "",
                                    targetRestSeconds: 0,
                                    sets: [SetLog(completedAt: Date(timeIntervalSince1970: 1_700_005_600),
                                                  climbGradeLabel: "6b/V4",
                                                  climbStatusRaw: "sent", climbAttempts: 3)])
        climb.kindRaw = SetKind.climbAttempt.rawValue
        return WorkoutSession(routineID: routineID, routineName: "Push day",
                              startedAt: Date(timeIntervalSince1970: 1_700_005_000),
                              completedAt: Date(timeIntervalSince1970: 1_700_005_000 + 3600),
                              exercises: [exercise, climb],
                              hrSeries: hr, maxHR: 190.5, restHR: 51,
                              metricsSourceRaw: "appleWatch", kcalEstimate: 512.25)
    }

    /// A studio project exercising every composite: clips with keyframes/adjust, a
    /// transition, text + PiP overlays (per-axis size), audio tracks, HR overlay, baseFrame.
    private func makeStudioProject(sessionID: UUID) -> StudioProject {
        let clipA = TimelineClip(sessionMediaID: UUID(), localIdentifier: "asset-A", isPhoto: false,
                                 order: 0, trimStart: 0.5, trimEnd: 6.5, speed: 1.5,
                                 cropRect: CGRect(x: 0, y: 0.1, width: 1, height: 0.8),
                                 filter: .vivid, filterIntensity: 0.7,
                                 adjust: ClipAdjust(brightness: 0.1, contrast: 1.1, saturation: 0.9),
                                 volume: 0.5,
                                 scaleKeyframes: [StudioKeyframe(timeSec: 0, value: 1),
                                                  StudioKeyframe(timeSec: 3, value: 1.3, easing: .easeOut)])
        let clipB = TimelineClip(sessionMediaID: nil, localIdentifier: "asset-B", isPhoto: true,
                                 order: 1, photoDurationSec: 2.5)
        var pip = OverlayItem(kind: .video, content: "asset-C", startSec: 1, endSec: 5,
                              position: CGPoint(x: 0.75, y: 0.25), scale: 0.4)
        pip.pipSize = CGSize(width: 0.5, height: 0.33)
        let text = OverlayItem(kind: .climbName, content: "Crimpy · 6a/V3 · 40°",
                               startSec: 0, endSec: 3, colorHex: "#FFFFFF",
                               highlightHex: "#000000", font: .rounded, bold: false, italic: true)
        let project = StudioProject(sessionID: sessionID, title: "Session cut",
                                    background: .blur,
                                    clips: [clipA, clipB],
                                    transitions: [StudioTransition(afterClipID: clipA.id,
                                                                   kind: .dissolve, durationSec: 0.75)],
                                    overlays: [pip, text],
                                    audioTracks: [AudioTrack(kind: .music, sourceRef: "uplift",
                                                             startSec: 0, volume: 0.8,
                                                             fadeInSec: 1, fadeOutSec: 2)],
                                    hrOverlay: .default,
                                    baseFrame: .half,
                                    createdAt: Date(timeIntervalSince1970: 1_700_012_000))
        project.updatedAt = Date(timeIntervalSince1970: 1_700_012_600)
        return project
    }
}
