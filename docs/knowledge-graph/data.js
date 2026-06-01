/*
 * Snappet Mobile — App Knowledge Graph data model.
 *
 * A hand-curated map of the app's wireframe + workflow: every screen, sheet,
 * module, service, engine component and data model, plus the navigation and
 * data-flow edges that wire them together.
 *
 * This is the single source of truth the visualizer renders. To extend the
 * graph, add a node to `nodes` and connect it with an edge in `links` — the UI,
 * search, filters and layouts all derive from this file automatically.
 *
 * node.type     — drives colour, shape and the type legend/filter
 * node.group     — the owning mini-app / subsystem (drives clustering + grouped layout)
 * node.category  — App Library grouping: fitness | productivity | finance | core | platform
 * node.platform  — "ios" | "ios+android" | "watchos" | "engine" | "external"
 * link.type      — navigation semantics (see EDGE_TYPES below)
 */

const NODE_TYPES = {
  root:    { label: "App entry",   color: "#f5f5f7", shape: "diamond" },
  shell:   { label: "Shell / Tab", color: "#8e8e93", shape: "roundrect" },
  module:  { label: "Mini-app",    color: "#0a84ff", shape: "hexagon" },
  screen:  { label: "Screen",      color: "#30d158", shape: "rect" },
  section: { label: "Section",     color: "#64d2ff", shape: "rect" },
  sheet:   { label: "Sheet / Modal",color: "#ff9f0a", shape: "rect" },
  cover:   { label: "Full-screen", color: "#ff375f", shape: "rect" },
  service: { label: "Service",     color: "#bf5af2", shape: "roundrect" },
  engine:  { label: "Engine core", color: "#ff453a", shape: "hexagon" },
  core:    { label: "Core infra",  color: "#5e5ce6", shape: "roundrect" },
  model:   { label: "Data model",  color: "#ffd60a", shape: "cylinder" },
  watch:   { label: "watchOS",     color: "#66d4cf", shape: "roundrect" },
  widget:  { label: "Widget",      color: "#ac8e68", shape: "roundrect" },
  external:{ label: "OS framework",color: "#98989d", shape: "diamond" },
};

const EDGE_TYPES = {
  contains:  { label: "contains",     color: "#6e6e73", dash: false,  arrow: true  },
  navigate:  { label: "push (nav)",   color: "#30d158", dash: false,  arrow: true  },
  present:   { label: "present sheet",color: "#ff9f0a", dash: true,   arrow: true  },
  cover:     { label: "full-screen",  color: "#ff375f", dash: true,   arrow: true  },
  uses:      { label: "uses",         color: "#bf5af2", dash: true,   arrow: true  },
  persists:  { label: "persists to",  color: "#ffd60a", dash: [2,4],  arrow: true  },
  feeds:     { label: "data flow",    color: "#ff453a", dash: [6,4],  arrow: true  },
  streams:   { label: "streams",      color: "#66d4cf", dash: [6,4],  arrow: true  },
};

// ---- Mini-app accent colours (mirror the SwiftUI `tint:` on each AppModule) ----
const GROUP_COLORS = {
  shell:        "#8e8e93",
  workout:      "#ff2d92", // pink   — Workout Reels (flagship)
  "workout-log":"#ff9f0a", // orange — Workout tracker
  pomodoro:     "#ff453a", // red
  habit:        "#30d158", // green
  journal:      "#5e5ce6", // indigo
  tip:          "#63e6be", // mint
  expense:      "#40c8c8", // teal
  budget:       "#0a84ff", // blue
  core:         "#5e5ce6",
  engine:       "#ff453a",
  watch:        "#66d4cf",
  platform:     "#98989d",
};

const nodes = [
  // ───────────────────────── App shell ─────────────────────────
  { id: "app", label: "SnappetApp", type: "root", group: "shell", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/SnappetApp.swift", desc: "App entry point. Builds the SwiftData ModelContainer and hands off to RootShell.", tags: ["entry","swiftdata"] },
  { id: "rootshell", label: "RootShell", type: "shell", group: "shell", category: "core", platform: "ios",
    file: "ios/App/Snappet/Features/Shell/RootShell.swift", desc: "Constructs SnappetCore from the model context, then shows the suite shell. Has a -screenshotModule QA hook to open one module full-screen.", tags: ["root","qa-hook"] },
  { id: "shelltabs", label: "ShellTabs (TabView)", type: "shell", group: "shell", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Features/Shell/RootShell.swift", desc: "Top-level TabView with two tabs: Home dashboard and the App Library. --start-tab apps QA hook opens straight to Apps.", tags: ["tabview","navigation"] },
  { id: "tab-home", label: "Home tab", type: "shell", group: "shell", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Features/Shell/RootShell.swift", desc: "Bottom-nav tab → HomeDashboardView.", tags: ["tab"] },
  { id: "tab-apps", label: "Apps tab", type: "shell", group: "shell", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Features/Shell/RootShell.swift", desc: "Bottom-nav tab → AppLibraryView.", tags: ["tab"] },
  { id: "home", label: "HomeDashboardView", type: "screen", group: "shell", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Features/Home/HomeDashboardView.swift", desc: "Aggregates historical usage across every mini-app (Swift Charts) from Snappet Core's UsageRecords.", tags: ["dashboard","charts"] },
  { id: "applibrary", label: "AppLibraryView", type: "screen", group: "shell", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Features/AppLibrary/AppLibraryView.swift", desc: "Grid of mini-apps grouped by category. Owns the shared NavigationStack; each tap pushes a ModuleRoute onto SuiteRouter.path.", tags: ["library","router"] },

  // ───────────────────────── Core infra ─────────────────────────
  { id: "snappetcore", label: "SnappetCore", type: "core", group: "core", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Core/SnappetCore.swift", desc: "The shared on-device SwiftData store. Every mini-app logs UsageRecords here; the Home dashboard aggregates them. On-device only — no backend, no sync.", tags: ["store","swiftdata","privacy"] },
  { id: "appmodel", label: "AppModel", type: "core", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Core/AppModel.swift", desc: "The flagship Workout Reels orchestrator: holds phase, the HighlightEngine selector, services, and live-workout state. The one place the engine meets the app.", tags: ["state","orchestrator"] },
  { id: "moduleregistry", label: "ModuleRegistry", type: "core", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Core/ModuleRegistry.swift", desc: "Single source of truth for which mini-apps exist. Add a module by appending one line.", tags: ["registry"] },
  { id: "suiterouter", label: "SuiteRouter", type: "core", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Core/SuiteRouter.swift", desc: "Shared programmatic NavigationPath. Mini-apps push route values onto it instead of nesting their own NavigationStack.", tags: ["navigation","path"] },
  { id: "feedbackstore", label: "FeedbackStore", type: "core", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Core/FeedbackStore.swift", desc: "Persists HighlightFeedbackEvents (every reel edit) to highlight-feedback.jsonl — the training data that turns the synthetic spike into a data-driven GO.", tags: ["feedback","jsonl"] },

  // ───────────────────────── Onboarding ─────────────────────────
  { id: "onboarding", label: "OnboardingView", type: "screen", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Onboarding/OnboardingView.swift", desc: "Value-first, just-in-time Health + Photos permission priming. Scoped to the Workout Reels module so the rest of the suite opens instantly.", tags: ["permissions","onboarding"] },

  // ═════════════════ MODULE: Workout Reels (flagship) ═════════════════
  { id: "m-workout", label: "Workout Reels", type: "module", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Workout/WorkoutModule.swift", desc: "Flagship mini-app: HR-driven auto-highlight reels. Reads a workout's HealthKit heart-rate series, finds media shot in the workout window, and assembles a reel ranked by HR intensity.", tags: ["flagship","reels","hr"] },
  { id: "workout-modulev", label: "WorkoutModuleView", type: "screen", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Workout/WorkoutModule.swift", desc: "Phase gate for the flagship: onboarding → loading → error → ready. Handles its own Health/Photos priming on first entry.", tags: ["phase-gate"] },
  { id: "workout-list", label: "WorkoutListView", type: "screen", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Workout/WorkoutListView.swift", desc: "Lists completed Apple-Watch workouts (from HealthKit). Tap a workout to push its reel.", tags: ["list","healthkit"] },
  { id: "reel", label: "ReelView", type: "screen", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Reel/ReelView.swift", desc: "The flagship screen: a finished reel by default with one-tap Regenerate / Share and a light edit list. Auto-generate-then-edit — casual users never open the list; power users curate it.", tags: ["reel","editor","share"] },
  { id: "reel-vm", label: "ReelViewModel", type: "core", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Reel/ReelView.swift", desc: "Drives reel state: loading → ready → exporting → exported. Calls the engine to plan, pin/reorder/restore clips, and emits feedback events on every edit.", tags: ["viewmodel"] },
  { id: "mediapicker", label: "MediaPicker", type: "sheet", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Services/MediaPicker.swift", desc: "PHPicker fallback for limited Photo access — manually select the clips shot during the session.", tags: ["phpicker","fallback"] },
  { id: "sharesheet", label: "ShareSheet", type: "sheet", group: "workout", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/Reel/ReelView.swift", desc: "System share sheet for the exported reel video.", tags: ["share"] },

  // ═════════════════ MODULE: Workout tracker ═════════════════
  { id: "m-workout-log", label: "Workout (tracker)", type: "module", group: "workout-log", category: "fitness", platform: "ios+android",
    file: "ios/App/Snappet/Features/WorkoutTracker/WorkoutTrackerModule.swift", desc: "Full gym/strength tracker: 870+ exercises, routines, a guided session with set logging + rest timer, history, PRs and progress. Bundled catalog, fully offline.", tags: ["gym","routines"] },
  { id: "wt-home", label: "WorkoutHomeView", type: "screen", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/WorkoutTrackerModule.swift", desc: "Root with a segmented control switching 5 sections: Dashboard, Exercises, Routines, History, Settings. Owns all navigationDestinations, sheets and the full-screen player.", tags: ["root","segmented"] },
  { id: "wt-dashboard", label: "Dashboard section", type: "section", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/WorkoutDashboardSection.swift", desc: "Overview: active-session banner, recent routines, PR/progress shortcuts.", tags: ["section"] },
  { id: "wt-browse", label: "Exercises (browse)", type: "section", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/ExerciseBrowserView.swift", desc: "Searchable/filterable catalog of 870+ exercises. Tap to push exercise detail; + to add a custom exercise.", tags: ["section","catalog"] },
  { id: "wt-routines", label: "Routines section", type: "section", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/RoutinesSectionView.swift", desc: "List of routines; start a workout, open detail, or create a new routine.", tags: ["section"] },
  { id: "wt-history", label: "History section", type: "section", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/HistorySectionView.swift", desc: "Completed sessions; tap to push session detail.", tags: ["section"] },
  { id: "wt-settings", label: "Settings section", type: "section", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/WorkoutSettingsView.swift", desc: "Preferred weight unit + custom-exercise management.", tags: ["section","settings"] },
  { id: "wt-exercise-detail", label: "ExerciseDetailView", type: "screen", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/ExerciseDetailView.swift", desc: "An exercise's history, instructions and PRs. Pushes progress; opens an edit sheet.", tags: ["detail"] },
  { id: "wt-routine-detail", label: "RoutineDetailView", type: "screen", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/RoutineDetailView.swift", desc: "A routine's exercises; Start launches the live player. Edit opens the routine editor.", tags: ["detail"] },
  { id: "wt-session-detail", label: "SessionDetailView", type: "screen", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift", desc: "A completed session's set-by-set breakdown (pushed by SessionRoute id to avoid colliding with the live-player cover).", tags: ["detail"] },
  { id: "wt-progress", label: "ExerciseProgressView", type: "screen", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/ExerciseProgressView.swift", desc: "Charted progress over time for one exercise (pushed by ProgressRoute).", tags: ["detail","charts"] },
  { id: "wt-player", label: "WorkoutPlayerView", type: "cover", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/WorkoutPlayerView.swift", desc: "Full-screen guided session: per-set logging, rest timer, live HR. Starts watch live-metrics + a Live Activity; on close, saves or discards.", tags: ["player","fullscreen","live"] },
  { id: "wt-routine-editor", label: "RoutineEditorView", type: "sheet", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/RoutineEditorView.swift", desc: "Create/edit a routine; presents the exercise picker to add exercises.", tags: ["editor"] },
  { id: "wt-exercise-editor", label: "ExerciseEditorView", type: "sheet", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/ExerciseEditorView.swift", desc: "Create/edit a custom exercise.", tags: ["editor"] },
  { id: "wt-exercise-picker", label: "ExercisePickerView", type: "sheet", group: "workout-log", category: "fitness", platform: "ios",
    file: "ios/App/Snappet/Features/WorkoutTracker/ExercisePickerView.swift", desc: "Multi-select exercise picker (with its own filters sheet) used while editing a routine.", tags: ["picker"] },

  // ═════════════════ MODULE: Pomodoro ═════════════════
  { id: "m-pomodoro", label: "Pomodoro", type: "module", group: "pomodoro", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Pomodoro/PomodoroModule.swift", desc: "Focus timer with session history and persisted settings.", tags: ["timer","focus"] },
  { id: "pomodoro-root", label: "PomodoroRootView", type: "screen", group: "pomodoro", category: "productivity", platform: "ios",
    file: "ios/App/Snappet/Features/Pomodoro/PomodoroRootView.swift", desc: "The timer face + a 7-day focus chart. Pushes History; presents Settings.", tags: ["root","timer"] },
  { id: "pomodoro-history", label: "PomodoroHistoryView", type: "screen", group: "pomodoro", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Pomodoro/PomodoroHistoryView.swift", desc: "Past focus sessions (pushed via PomodoroRoute).", tags: ["history"] },
  { id: "pomodoro-settings", label: "PomodoroSettingsView", type: "sheet", group: "pomodoro", category: "productivity", platform: "ios",
    file: "ios/App/Snappet/Features/Pomodoro/PomodoroSettingsView.swift", desc: "Persisted work/break durations and round count.", tags: ["settings"] },

  // ═════════════════ MODULE: Habits ═════════════════
  { id: "m-habit", label: "Habits", type: "module", group: "habit", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Habit/HabitModule.swift", desc: "Daily streaks with a 7-day backfill strip and a 30-day completion rate.", tags: ["streaks"] },
  { id: "habit-root", label: "HabitRootView", type: "screen", group: "habit", category: "productivity", platform: "ios",
    file: "ios/App/Snappet/Features/Habit/HabitRootView.swift", desc: "List of habits with the 7-day strip + 30-day rate. Presents Add; presents Edit per habit.", tags: ["root","list"] },
  { id: "habit-add", label: "Add Habit", type: "sheet", group: "habit", category: "productivity", platform: "ios",
    file: "ios/App/Snappet/Features/Habit/HabitEditorView.swift", desc: "Create a new habit (presented from the + toolbar).", tags: ["editor"] },
  { id: "habit-editor", label: "HabitEditorView", type: "sheet", group: "habit", category: "productivity", platform: "ios",
    file: "ios/App/Snappet/Features/Habit/HabitEditorView.swift", desc: "Edit an existing habit (presented via the editing item).", tags: ["editor"] },

  // ═════════════════ MODULE: Journal ═════════════════
  { id: "m-journal", label: "Journal", type: "module", group: "journal", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Journal/JournalModule.swift", desc: "Quick notes & entries with tags and .searchable filtering.", tags: ["notes","tags","search"] },
  { id: "journal-root", label: "JournalRootView", type: "screen", group: "journal", category: "productivity", platform: "ios",
    file: "ios/App/Snappet/Features/Journal/JournalRootView.swift", desc: "Searchable list of entries (tag chips). Pushes an entry to its editor; presents a new entry.", tags: ["root","search"] },
  { id: "journal-editor", label: "JournalEditorView", type: "screen", group: "journal", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Journal/JournalEditorView.swift", desc: "Compose/edit an entry with tags. Reached by pushing an existing JournalEntry or by the new-entry item.", tags: ["editor"] },

  // ═════════════════ MODULE: Tip Calculator ═════════════════
  { id: "m-tip", label: "Tip Calculator", type: "module", group: "tip", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Tip/TipModule.swift", desc: "Split the bill: calculation history, editable presets and round-up.", tags: ["tip","split"] },
  { id: "tip-root", label: "TipRootView", type: "screen", group: "tip", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Tip/TipRootView.swift", desc: "Bill + tip% + party size with round-up. Pushes History; presents the preset editor.", tags: ["root","calculator"] },
  { id: "tip-history", label: "TipHistoryView", type: "screen", group: "tip", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Tip/TipHistoryView.swift", desc: "Saved calculations (pushed via TipHistoryRoute).", tags: ["history"] },
  { id: "tip-presets", label: "Edit Presets", type: "sheet", group: "tip", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Tip/TipRootView.swift", desc: "Editable tip-percentage presets (presented sheet).", tags: ["settings"] },

  // ═════════════════ MODULE: Split Expenses ═════════════════
  { id: "m-expense", label: "Split Expenses", type: "module", group: "expense", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Expense/ExpenseModule.swift", desc: "Settle up with friends: groups, expenses, manual settlements.", tags: ["split","groups"] },
  { id: "expense-root", label: "ExpenseRootView", type: "screen", group: "expense", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Expense/ExpenseRootView.swift", desc: "List of groups + balances. Pushes a group; presents New Group.", tags: ["root","list"] },
  { id: "expense-group", label: "ExpenseGroupView", type: "screen", group: "expense", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Expense/ExpenseGroupView.swift", desc: "A group's expenses + who-owes-whom. Presents new/edit expense, record settlement, and edit group.", tags: ["detail"] },
  { id: "expense-newgroup", label: "NewGroupSheet", type: "sheet", group: "expense", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Expense/NewGroupSheet.swift", desc: "Create a group (also reused for editing a group).", tags: ["editor"] },
  { id: "expense-newexpense", label: "NewExpenseSheet", type: "sheet", group: "expense", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Expense/NewExpenseSheet.swift", desc: "Add or edit an expense with a split.", tags: ["editor"] },
  { id: "expense-settlement", label: "RecordSettlementSheet", type: "sheet", group: "expense", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Expense/RecordSettlementSheet.swift", desc: "Record a manual settlement (someone paid someone back).", tags: ["settlement"] },

  // ═════════════════ MODULE: Budget ═════════════════
  { id: "m-budget", label: "Budget", type: "module", group: "budget", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Budget/BudgetModule.swift", desc: "Track monthly spending: categories, transactions, a month switcher and 6-month trends.", tags: ["budget","spending"] },
  { id: "budget-root", label: "BudgetRootView", type: "screen", group: "budget", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Budget/BudgetRootView.swift", desc: "Month summary + spend-by-category. Pushes a category and Trends; presents add/edit category and add transaction.", tags: ["root","charts"] },
  { id: "budget-cat-tx", label: "BudgetCategoryTransactionsView", type: "screen", group: "budget", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Budget/BudgetCategoryTransactionsView.swift", desc: "A category's transactions (pushed via BudgetCategory); presents an edit-transaction sheet.", tags: ["detail"] },
  { id: "budget-trends", label: "BudgetTrendsView", type: "screen", group: "budget", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Budget/BudgetTrendsView.swift", desc: "6-month spending trends (pushed via BudgetTrendsRoute).", tags: ["trends","charts"] },
  { id: "budget-add-cat", label: "Add Category", type: "sheet", group: "budget", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Budget/BudgetCategoryEditor.swift", desc: "Create a budget category.", tags: ["editor"] },
  { id: "budget-cat-editor", label: "BudgetCategoryEditor", type: "sheet", group: "budget", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Budget/BudgetCategoryEditor.swift", desc: "Edit a budget category (limit, name, colour).", tags: ["editor"] },
  { id: "budget-add-tx", label: "AddTransactionView", type: "sheet", group: "budget", category: "finance", platform: "ios",
    file: "ios/App/Snappet/Features/Budget/AddTransactionView.swift", desc: "Add a transaction to a category.", tags: ["editor"] },

  // ═════════════════ Flagship services ═════════════════
  { id: "healthkitservice", label: "HealthKitService", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/HealthKitService.swift", desc: "Reads completed-workout heart-rate series from HealthKit. Device-only — does not run in the simulator.", tags: ["healthkit","hr"] },
  { id: "photolibraryservice", label: "PhotoLibraryService", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/PhotoLibraryService.swift", desc: "Time-window media discovery via PhotoKit, with limited-access mapping. Device-only.", tags: ["photos","media"] },
  { id: "reelexporter", label: "ReelExporter", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/ReelExporter.swift", desc: "On-device reel export with AVFoundation (AVMutableComposition + AVAssetExportSession), shared makeComposition.", tags: ["avfoundation","export"] },
  { id: "photoclciprenderer", label: "PhotoClipRenderer", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/PhotoClipRenderer.swift", desc: "Turns photos into Ken-Burns clips interleaved into the reel.", tags: ["kenburns","photos"] },
  { id: "liveworkoutservice", label: "LiveWorkoutService", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/LiveWorkoutService.swift", desc: "Bridges the watch HKWorkoutSession to the phone: starts/stops the activity and ingests streamed live HR.", tags: ["live","hr","watch"] },
  { id: "liveactivitycontroller", label: "LiveActivityController", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/LiveActivityController.swift", desc: "Drives the Lock Screen / Dynamic Island Live Activity: overall timer, live HR, current exercise.", tags: ["live-activity"] },
  { id: "workoutactivitymapping", label: "WorkoutActivityMapping", type: "service", group: "core", category: "core", platform: "ios",
    file: "ios/App/Snappet/Services/WorkoutActivityMapping.swift", desc: "Maps a routine's sport/dominant-category to the HKWorkoutActivityType the watch should record.", tags: ["mapping"] },

  // ═════════════════ HighlightEngine (pure-Swift SPM, zero platform deps) ═════════════════
  { id: "highlightengine", label: "HighlightEngine", type: "engine", group: "engine", category: "core", platform: "engine",
    file: "ios/HighlightEngine/Sources/HighlightEngine/HighlightEngine.swift", desc: "Pure-Swift SPM package — the swappable selection algorithm with ZERO platform deps. Unit-tested (18 XCTest cases).", tags: ["spm","algorithm","platform-free"] },
  { id: "heartrateseries", label: "HeartRateSeries", type: "engine", group: "engine", category: "core", platform: "engine",
    file: "ios/HighlightEngine/Sources/HighlightEngine/HeartRateSeries.swift", desc: "Resample → smooth → %HRR → derivative. Turns raw HR samples into an intensity signal.", tags: ["hr","%hrr"] },
  { id: "highlightselector", label: "HighlightSelector", type: "engine", group: "engine", category: "core", platform: "engine",
    file: "ios/HighlightEngine/Sources/HighlightEngine/HighlightSelector.swift", desc: "Protocol with HRHighlightSelector + SceneHighlightSelector stub + FusionSelector. Pluggable so HR-only → fusion is a one-line swap.", tags: ["selector","pluggable"] },
  { id: "highlightconfig", label: "HighlightConfig", type: "engine", group: "engine", category: "core", platform: "engine",
    file: "ios/HighlightEngine/Sources/HighlightEngine/HighlightConfig.swift", desc: "Per-activity presets and tunable knobs (changed only from replayed feedback, never intuition).", tags: ["config","tuning"] },
  { id: "reelplanner", label: "ReelPlanner", type: "engine", group: "engine", category: "core", platform: "engine",
    file: "ios/HighlightEngine/Sources/HighlightEngine/ReelPlan.swift", desc: "Builds the final clip plan: pin budget-exemption + manual order.", tags: ["planner"] },
  { id: "engine-feedback", label: "HighlightFeedback", type: "engine", group: "engine", category: "core", platform: "engine",
    file: "ios/HighlightEngine/Sources/HighlightEngine/Feedback.swift", desc: "HighlightFeedbackEvent + FeedbackSink — the contract the app's FeedbackStore implements so every edit becomes training data.", tags: ["feedback","sink"] },

  // ═════════════════ watchOS companion ═════════════════
  { id: "watchapp", label: "SnappetWatchApp", type: "watch", group: "watch", category: "fitness", platform: "watchos",
    file: "ios/App/SnappetWatch/SnappetWatchApp.swift", desc: "watchOS companion entry point.", tags: ["watchos","entry"] },
  { id: "watchview", label: "WatchWorkoutView", type: "watch", group: "watch", category: "fitness", platform: "watchos",
    file: "ios/App/SnappetWatch/WatchWorkoutView.swift", desc: "Live workout face on the watch: HR + timers.", tags: ["watchos","live"] },
  { id: "watchmanager", label: "WorkoutWatchManager", type: "watch", group: "watch", category: "fitness", platform: "watchos",
    file: "ios/App/SnappetWatch/WorkoutWatchManager.swift", desc: "Runs the HKWorkoutSession on the watch and streams HR samples to the phone.", tags: ["watchos","hkworkout"] },
  { id: "watchlink", label: "WatchConnectivityLink", type: "watch", group: "watch", category: "fitness", platform: "watchos",
    file: "ios/App/SnappetWatch/WatchConnectivityLink.swift", desc: "WatchConnectivity transport relaying live HR/control messages between watch and phone.", tags: ["watchconnectivity"] },

  // ═════════════════ Widget / Live Activity ═════════════════
  { id: "liveactivity-widget", label: "WorkoutLiveActivity", type: "widget", group: "watch", category: "fitness", platform: "ios",
    file: "ios/App/SnappetWidgets/WorkoutLiveActivity.swift", desc: "WidgetKit Live Activity UI for the Lock Screen + Dynamic Island.", tags: ["widgetkit","live-activity"] },

  // ═════════════════ Data models (SwiftData @Model) ═════════════════
  { id: "model-usage", label: "UsageRecord", type: "model", group: "core", category: "core", platform: "ios+android",
    file: "ios/App/Snappet/Core/SnappetCore.swift", desc: "Cross-suite activity log (module, action, summary, metric). The Home dashboard reads these.", tags: ["@model"] },
  { id: "model-workout", label: "Workout models", type: "model", group: "workout-log", category: "fitness", platform: "ios+android",
    file: "ios/App/Snappet/Features/WorkoutTracker/WorkoutModels.swift", desc: "Routine, WorkoutSession, SessionExercise, SetLog, CustomExercise.", tags: ["@model"] },
  { id: "model-pomodoro", label: "PomodoroSession", type: "model", group: "pomodoro", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Pomodoro/PomodoroSession.swift", desc: "A completed focus session.", tags: ["@model"] },
  { id: "model-habit", label: "Habit models", type: "model", group: "habit", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Habit/HabitModels.swift", desc: "Habit + its completion log.", tags: ["@model"] },
  { id: "model-journal", label: "JournalEntry", type: "model", group: "journal", category: "productivity", platform: "ios+android",
    file: "ios/App/Snappet/Features/Journal/JournalEntry.swift", desc: "A journal entry with tags.", tags: ["@model"] },
  { id: "model-tip", label: "Tip models", type: "model", group: "tip", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Tip/TipModels.swift", desc: "Saved tip calculations + presets.", tags: ["@model"] },
  { id: "model-expense", label: "Expense models", type: "model", group: "expense", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Expense/ExpenseModels.swift", desc: "ExpenseGroup, Expense, Settlement.", tags: ["@model"] },
  { id: "model-budget", label: "Budget models", type: "model", group: "budget", category: "finance", platform: "ios+android",
    file: "ios/App/Snappet/Features/Budget/BudgetModels.swift", desc: "BudgetCategory + Transaction.", tags: ["@model"] },

  // ═════════════════ OS frameworks (external) ═════════════════
  { id: "ext-healthkit", label: "HealthKit", type: "external", group: "platform", category: "platform", platform: "external",
    file: "—", desc: "Apple Health store. Source of completed-workout heart-rate. Device-only.", tags: ["apple","health"] },
  { id: "ext-photos", label: "Photos / PhotoKit", type: "external", group: "platform", category: "platform", platform: "external",
    file: "—", desc: "Photo library. Source of media shot during the workout window. Device-only.", tags: ["apple","photos"] },
  { id: "ext-avfoundation", label: "AVFoundation", type: "external", group: "platform", category: "platform", platform: "external",
    file: "—", desc: "Composition + export pipeline for the reel video.", tags: ["apple","video"] },
  { id: "ext-swiftdata", label: "SwiftData", type: "external", group: "platform", category: "platform", platform: "external",
    file: "—", desc: "On-device persistence backing Snappet Core and every @Model.", tags: ["apple","persistence"] },
  { id: "ext-widgetkit", label: "WidgetKit / ActivityKit", type: "external", group: "platform", category: "platform", platform: "external",
    file: "—", desc: "Live Activities on the Lock Screen + Dynamic Island.", tags: ["apple","widgets"] },
];

const links = [
  // ---- Shell containment + tab routing ----
  { source: "app", target: "rootshell", type: "contains" },
  { source: "rootshell", target: "shelltabs", type: "contains" },
  { source: "rootshell", target: "snappetcore", type: "uses" },
  { source: "shelltabs", target: "tab-home", type: "contains" },
  { source: "shelltabs", target: "tab-apps", type: "contains" },
  { source: "tab-home", target: "home", type: "navigate" },
  { source: "tab-apps", target: "applibrary", type: "navigate" },

  // ---- App Library → every module (push ModuleRoute) ----
  { source: "applibrary", target: "suiterouter", type: "uses" },
  { source: "applibrary", target: "moduleregistry", type: "uses" },
  { source: "applibrary", target: "m-workout", type: "navigate" },
  { source: "applibrary", target: "m-workout-log", type: "navigate" },
  { source: "applibrary", target: "m-pomodoro", type: "navigate" },
  { source: "applibrary", target: "m-habit", type: "navigate" },
  { source: "applibrary", target: "m-journal", type: "navigate" },
  { source: "applibrary", target: "m-tip", type: "navigate" },
  { source: "applibrary", target: "m-expense", type: "navigate" },
  { source: "applibrary", target: "m-budget", type: "navigate" },

  // ModuleRegistry collects all modules
  { source: "moduleregistry", target: "m-workout", type: "contains" },
  { source: "moduleregistry", target: "m-workout-log", type: "contains" },
  { source: "moduleregistry", target: "m-pomodoro", type: "contains" },
  { source: "moduleregistry", target: "m-habit", type: "contains" },
  { source: "moduleregistry", target: "m-journal", type: "contains" },
  { source: "moduleregistry", target: "m-tip", type: "contains" },
  { source: "moduleregistry", target: "m-expense", type: "contains" },
  { source: "moduleregistry", target: "m-budget", type: "contains" },

  // Home dashboard reads cross-suite usage
  { source: "home", target: "snappetcore", type: "uses" },
  { source: "snappetcore", target: "model-usage", type: "persists" },
  { source: "home", target: "model-usage", type: "feeds" },

  // ---- Workout Reels (flagship) flow ----
  { source: "m-workout", target: "workout-modulev", type: "contains" },
  { source: "workout-modulev", target: "onboarding", type: "navigate", label: "phase = onboarding" },
  { source: "workout-modulev", target: "workout-list", type: "navigate", label: "phase = ready" },
  { source: "workout-modulev", target: "appmodel", type: "uses" },
  { source: "workout-list", target: "reel", type: "navigate", label: "tap workout" },
  { source: "workout-list", target: "healthkitservice", type: "uses" },
  { source: "reel", target: "reel-vm", type: "uses" },
  { source: "reel", target: "mediapicker", type: "present" },
  { source: "reel", target: "sharesheet", type: "present" },
  { source: "reel-vm", target: "appmodel", type: "uses" },
  { source: "reel-vm", target: "reelexporter", type: "uses" },
  { source: "reel-vm", target: "feedbackstore", type: "feeds", label: "every edit" },
  { source: "mediapicker", target: "photolibraryservice", type: "uses" },

  // AppModel = the one place the engine meets the app
  { source: "appmodel", target: "highlightengine", type: "uses" },
  { source: "appmodel", target: "healthkitservice", type: "uses" },
  { source: "appmodel", target: "photolibraryservice", type: "uses" },
  { source: "appmodel", target: "reelexporter", type: "uses" },
  { source: "appmodel", target: "liveworkoutservice", type: "uses" },
  { source: "appmodel", target: "liveactivitycontroller", type: "uses" },
  { source: "onboarding", target: "healthkitservice", type: "uses" },
  { source: "onboarding", target: "photolibraryservice", type: "uses" },

  // Services → OS frameworks
  { source: "healthkitservice", target: "ext-healthkit", type: "uses" },
  { source: "photolibraryservice", target: "ext-photos", type: "uses" },
  { source: "reelexporter", target: "ext-avfoundation", type: "uses" },
  { source: "reelexporter", target: "photoclciprenderer", type: "uses" },
  { source: "photoclciprenderer", target: "ext-photos", type: "uses" },
  { source: "liveactivitycontroller", target: "liveactivity-widget", type: "feeds" },
  { source: "liveactivity-widget", target: "ext-widgetkit", type: "uses" },

  // Engine internals + feedback loop
  { source: "highlightengine", target: "heartrateseries", type: "contains" },
  { source: "highlightengine", target: "highlightselector", type: "contains" },
  { source: "highlightengine", target: "highlightconfig", type: "contains" },
  { source: "highlightengine", target: "reelplanner", type: "contains" },
  { source: "highlightengine", target: "engine-feedback", type: "contains" },
  { source: "healthkitservice", target: "heartrateseries", type: "feeds", label: "HR samples" },
  { source: "highlightselector", target: "reelplanner", type: "feeds" },
  { source: "feedbackstore", target: "engine-feedback", type: "uses" },

  // ---- Workout tracker flow ----
  { source: "m-workout-log", target: "wt-home", type: "contains" },
  { source: "wt-home", target: "wt-dashboard", type: "contains", label: "segment" },
  { source: "wt-home", target: "wt-browse", type: "contains", label: "segment" },
  { source: "wt-home", target: "wt-routines", type: "contains", label: "segment" },
  { source: "wt-home", target: "wt-history", type: "contains", label: "segment" },
  { source: "wt-home", target: "wt-settings", type: "contains", label: "segment" },
  { source: "wt-home", target: "wt-exercise-detail", type: "navigate", label: "Exercise" },
  { source: "wt-home", target: "wt-routine-detail", type: "navigate", label: "Routine" },
  { source: "wt-home", target: "wt-session-detail", type: "navigate", label: "SessionRoute" },
  { source: "wt-home", target: "wt-progress", type: "navigate", label: "ProgressRoute" },
  { source: "wt-home", target: "wt-player", type: "cover", label: "Start workout" },
  { source: "wt-home", target: "wt-routine-editor", type: "present", label: "New routine" },
  { source: "wt-home", target: "wt-exercise-editor", type: "present", label: "New exercise" },
  { source: "wt-browse", target: "wt-exercise-detail", type: "navigate" },
  { source: "wt-routines", target: "wt-routine-detail", type: "navigate" },
  { source: "wt-routines", target: "wt-player", type: "cover", label: "Start" },
  { source: "wt-history", target: "wt-session-detail", type: "navigate" },
  { source: "wt-dashboard", target: "wt-routine-detail", type: "navigate" },
  { source: "wt-dashboard", target: "wt-progress", type: "navigate" },
  { source: "wt-exercise-detail", target: "wt-progress", type: "navigate" },
  { source: "wt-exercise-detail", target: "wt-exercise-editor", type: "present", label: "Edit" },
  { source: "wt-routine-detail", target: "wt-routine-editor", type: "present", label: "Edit" },
  { source: "wt-routine-detail", target: "wt-player", type: "cover", label: "Start" },
  { source: "wt-routine-editor", target: "wt-exercise-picker", type: "present" },
  { source: "wt-player", target: "liveworkoutservice", type: "uses", label: "live HR" },
  { source: "wt-player", target: "liveactivitycontroller", type: "uses" },
  { source: "wt-home", target: "workoutactivitymapping", type: "uses" },
  { source: "wt-home", target: "model-workout", type: "persists" },
  { source: "wt-home", target: "snappetcore", type: "feeds", label: "log usage" },

  // watch live-metrics chain
  { source: "liveworkoutservice", target: "watchlink", type: "streams" },
  { source: "watchlink", target: "watchmanager", type: "streams" },
  { source: "watchmanager", target: "ext-healthkit", type: "uses" },
  { source: "watchapp", target: "watchview", type: "contains" },
  { source: "watchview", target: "watchmanager", type: "uses" },

  // ---- Pomodoro ----
  { source: "m-pomodoro", target: "pomodoro-root", type: "contains" },
  { source: "pomodoro-root", target: "pomodoro-history", type: "navigate", label: "PomodoroRoute" },
  { source: "pomodoro-root", target: "pomodoro-settings", type: "present" },
  { source: "pomodoro-root", target: "model-pomodoro", type: "persists" },
  { source: "pomodoro-root", target: "snappetcore", type: "feeds", label: "log usage" },

  // ---- Habits ----
  { source: "m-habit", target: "habit-root", type: "contains" },
  { source: "habit-root", target: "habit-add", type: "present" },
  { source: "habit-root", target: "habit-editor", type: "present" },
  { source: "habit-root", target: "model-habit", type: "persists" },
  { source: "habit-root", target: "snappetcore", type: "feeds", label: "log usage" },

  // ---- Journal ----
  { source: "m-journal", target: "journal-root", type: "contains" },
  { source: "journal-root", target: "journal-editor", type: "navigate", label: "entry / new" },
  { source: "journal-root", target: "model-journal", type: "persists" },
  { source: "journal-root", target: "snappetcore", type: "feeds", label: "log usage" },

  // ---- Tip ----
  { source: "m-tip", target: "tip-root", type: "contains" },
  { source: "tip-root", target: "tip-history", type: "navigate", label: "TipHistoryRoute" },
  { source: "tip-root", target: "tip-presets", type: "present" },
  { source: "tip-root", target: "model-tip", type: "persists" },
  { source: "tip-root", target: "snappetcore", type: "feeds", label: "log usage" },

  // ---- Split Expenses ----
  { source: "m-expense", target: "expense-root", type: "contains" },
  { source: "expense-root", target: "expense-group", type: "navigate" },
  { source: "expense-root", target: "expense-newgroup", type: "present" },
  { source: "expense-group", target: "expense-newexpense", type: "present" },
  { source: "expense-group", target: "expense-settlement", type: "present" },
  { source: "expense-group", target: "expense-newgroup", type: "present", label: "Edit group" },
  { source: "expense-root", target: "model-expense", type: "persists" },
  { source: "expense-root", target: "snappetcore", type: "feeds", label: "log usage" },

  // ---- Budget ----
  { source: "m-budget", target: "budget-root", type: "contains" },
  { source: "budget-root", target: "budget-cat-tx", type: "navigate", label: "BudgetCategory" },
  { source: "budget-root", target: "budget-trends", type: "navigate", label: "TrendsRoute" },
  { source: "budget-root", target: "budget-add-cat", type: "present" },
  { source: "budget-root", target: "budget-cat-editor", type: "present" },
  { source: "budget-root", target: "budget-add-tx", type: "present" },
  { source: "budget-cat-tx", target: "budget-add-tx", type: "present", label: "Edit tx" },
  { source: "budget-root", target: "model-budget", type: "persists" },
  { source: "budget-root", target: "snappetcore", type: "feeds", label: "log usage" },

  // ---- SwiftData backs the store + every model ----
  { source: "snappetcore", target: "ext-swiftdata", type: "uses" },
];

// Expose for the renderer (also works as an ES module if imported).
const GRAPH = { nodes, links, NODE_TYPES, EDGE_TYPES, GROUP_COLORS };
if (typeof window !== "undefined") window.GRAPH = GRAPH;
if (typeof module !== "undefined") module.exports = GRAPH;
