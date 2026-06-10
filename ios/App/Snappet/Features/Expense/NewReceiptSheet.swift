import SwiftUI
import SwiftData

/// Sheet to add — or edit — an itemized **receipt** in a group: a list of line items, each
/// shared by its own set of people, plus tax and discount that are allocated
/// proportionally. Paste a receipt's text to auto-fill the items, then tap a line to choose
/// who shares it. A live `ReceiptSummaryView` shows the running total and per-person split.
/// Saving writes an `ExpenseRecord` whose `items`/`taxAmount`/`discountAmount` drive the
/// group balances via `ReceiptSplit`.
struct NewReceiptSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SnappetCore.self) private var core

    let group: ExpenseGroup
    /// The receipt being edited, or `nil` when adding a new one.
    let record: ExpenseRecord?

    @State private var title: String
    @State private var payer: String
    @State private var items: [ReceiptItem]
    @State private var taxAmount: Double
    @State private var discountAmount: Double
    /// One focus enum across every money field on the sheet (discount, tax, and each
    /// item's price) so the shared keypad Done toolbar can resign whichever is active
    /// and Save can commit-then-read (issue #82).
    enum MoneyField: Hashable { case discount, tax, itemPrice(UUID) }
    @FocusState private var focusedMoneyField: MoneyField?
    @State private var showingPaste = false
    @State private var showingScanner = false
    /// The receipt kind used to tune parsing; `.auto` resolves via `ReceiptClassifier` on scan/paste.
    @State private var receiptType: ReceiptType = .auto

    // Totals read off the most recent scan/paste, kept so `ReceiptValidation` can cross-check the
    // edited items against what the receipt actually printed. Nil until something is parsed.
    @State private var detectedSubtotal: Double?
    @State private var detectedTax: Double?
    @State private var detectedTotal: Double?
    @State private var detectedItemCount: Int?

    init(group: ExpenseGroup, record: ExpenseRecord? = nil) {
        self.group = group
        self.record = record
        _title = State(initialValue: record?.title ?? "")
        _payer = State(initialValue: record?.payer ?? group.participants.first ?? "")
        _items = State(initialValue: record?.items ?? [])
        _taxAmount = State(initialValue: record?.taxAmount ?? 0)
        _discountAmount = State(initialValue: record?.discountAmount ?? 0)
    }

    private var isEditing: Bool { record != nil }
    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }
    private func currency(_ value: Double) -> String { value.formatted(.currency(code: currencyCode)) }

    private var result: ReceiptSplit.Result {
        ReceiptSplit.compute(items: items, taxAmount: taxAmount,
                             discountAmount: discountAmount, order: group.participants)
    }

    /// Live cross-check of the current items against the scanned totals. Takes the already-computed
    /// `result` so the split isn't recomputed for the banner — `body` computes it once and reuses it.
    private func validation(for result: ReceiptSplit.Result) -> ReceiptValidation.Report {
        ReceiptValidation.validate(
            result: result,
            detectedSubtotal: detectedSubtotal,
            detectedTax: detectedTax,
            detectedTotal: detectedTotal,
            detectedItemCount: detectedItemCount,
            lineItemCount: items.filter { $0.price > 0 }.count
        )
    }

    var body: some View {
        // Compute the split (and its validation) once per render and reuse them for the banner and
        // the summary, rather than recomputing via separate computed properties.
        let result = result
        let report = validation(for: result)
        let showValidation = detectedTotal != nil || report.overall != .pass
        return NavigationStack {
            Form {
                detailsSection
                pasteSection
                if showValidation {
                    ReceiptValidationBanner(report: report)
                }
                itemsSection
                adjustmentsSection
                ReceiptSummaryView(result: result, currency: currency)
            }
            .navigationTitle(isEditing ? "Edit Receipt" : "New Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commitAndSave() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("expense.receipt.save")
                }
            }
            .keypadDoneToolbar($focusedMoneyField)
            .sheet(isPresented: $showingPaste) {
                PasteReceiptSheet { text in apply(parseText(text)) }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ReceiptDocumentScanner { text in
                    showingScanner = false
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    apply(parseText(text))
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section("Receipt") {
            TextField("Title (e.g. Costco run)", text: $title)
                .accessibilityIdentifier("expense.receipt.title")
            Picker("Paid by", selection: $payer) {
                ForEach(group.participants, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("expense.receipt.payer")
        }
    }

    private var pasteSection: some View {
        Section {
            Picker("Receipt type", selection: $receiptType) {
                ForEach(ReceiptType.allCases) { type in
                    Label(type.displayName, systemImage: type.symbol).tag(type)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("expense.receipt.type")

            if ReceiptDocumentScanner.isSupported {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan receipt with camera", systemImage: "camera.viewfinder")
                }
                .accessibilityIdentifier("expense.receipt.scan")
            }
            Button {
                showingPaste = true
            } label: {
                Label("Paste receipt text", systemImage: "doc.text.viewfinder")
            }
            .accessibilityIdentifier("expense.receipt.paste")
        } footer: {
            Text("Scan a receipt with the camera, or paste its text (e.g. from the camera's Live Text), and we'll pull out the line items, tax and discount.")
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach($items) { $item in
                ItemRow(item: $item, focus: $focusedMoneyField, participants: group.participants,
                        currencyCode: currencyCode)
            }
            .onDelete { items.remove(atOffsets: $0) }

            Button {
                items.append(ReceiptItem(name: "", price: 0, assignees: group.participants))
            } label: {
                Label("Add item", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("expense.receipt.addItem")
        } header: {
            Text("Items (\(items.count))")
        } footer: {
            Text("Tap an item to choose who shares it. New items default to everyone.")
        }
    }

    private var adjustmentsSection: some View {
        Section("Adjustments") {
            HStack {
                Text("Discount")
                Spacer()
                TextField("Amount", value: $discountAmount,
                          format: .currency(code: currencyCode))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedMoneyField, equals: .discount)
                    .accessibilityIdentifier("expense.receipt.discount")
            }
            HStack {
                Text("Tax")
                Spacer()
                TextField("Amount", value: $taxAmount,
                          format: .currency(code: currencyCode))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedMoneyField, equals: .tax)
                    .accessibilityIdentifier("expense.receipt.tax")
            }
        }
    }

    // MARK: - Actions

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !payer.isEmpty
            && items.contains { $0.price > 0 && !$0.assignees.isEmpty }
    }

    /// Parse `text` with the selected type's profile. When the type is `.auto`, classify the text
    /// and snap the picker to the detected type so the user sees what it decided.
    private func parseText(_ text: String) -> ReceiptParser.ParsedReceipt {
        let resolved = receiptType.resolved(for: text)
        if receiptType == .auto { receiptType = resolved }
        return ReceiptParser.parse(text, profile: resolved.profile)
    }

    /// Merge a parsed receipt into the current draft: append its items (defaulting each to
    /// everyone) and *add* its detected tax/discount. Accumulating (rather than overwriting) keeps
    /// a second paste / multi-page scan consistent with the way items append, and never silently
    /// clobbers a tax or discount the user typed in by hand.
    private func apply(_ parsed: ReceiptParser.ParsedReceipt) {
        let everyone = group.participants
        items.append(contentsOf: parsed.items.map {
            ReceiptItem(name: $0.name, price: $0.price, assignees: everyone)
        })
        discountAmount += parsed.discount
        if let tax = parsed.tax { taxAmount += tax }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = "Receipt"
        }
        // Remember what the receipt printed so the validation banner can cross-check.
        detectedSubtotal = parsed.subtotal
        detectedTax = parsed.tax
        detectedTotal = parsed.total
        detectedItemCount = parsed.itemCount
    }

    /// Resign-then-save so a mid-edit Save can't read a stale, uncommitted money field
    /// (value-formatted fields commit on focus loss — issue #82).
    private func commitAndSave() {
        guard focusedMoneyField != nil else { return save() }
        focusedMoneyField = nil
        Task { @MainActor in save() }
    }

    private func save() {
        guard canSave else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep only meaningful items; trim names.
        let cleaned = items
            .map { ReceiptItem(id: $0.id,
                               name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                               price: $0.price, assignees: $0.assignees) }
            .filter { $0.price > 0 }
        let computed = ReceiptSplit.compute(items: cleaned, taxAmount: taxAmount,
                                            discountAmount: discountAmount,
                                            order: group.participants)
        // Everyone who shares at least one item — used for edit/usage bookkeeping.
        let sharers = group.participants.filter { person in
            computed.perPerson.contains { $0.name == person }
        }

        if let record {
            record.title = trimmedTitle
            record.payer = payer
            record.amount = computed.grandTotal
            record.participants = sharers
            record.items = cleaned
            record.taxAmount = taxAmount
            record.discountAmount = discountAmount
        } else {
            let newRecord = ExpenseRecord(
                groupID: group.id, title: trimmedTitle, amount: computed.grandTotal,
                payer: payer, participants: sharers,
                items: cleaned, taxAmount: taxAmount, discountAmount: discountAmount
            )
            modelContext.insert(newRecord)
        }
        try? modelContext.save()

        let verb = isEditing ? "Edited" : "Added"
        core.log(module: "expense", action: "receipt",
                 summary: "\(verb) \(currency(computed.grandTotal)) receipt (\(cleaned.count) items)",
                 metric: computed.grandTotal)
        dismiss()
    }
}

/// One editable item line: name, price, and a push to choose who shares it.
private struct ItemRow: View {
    @Binding var item: ReceiptItem
    /// The sheet's shared money-field focus, so the keypad Done toolbar covers this row.
    var focus: FocusState<NewReceiptSheet.MoneyField?>.Binding
    let participants: [String]
    let currencyCode: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                TextField("Item", text: $item.name)
                    .accessibilityIdentifier("expense.receipt.item.name")
                TextField("Price", value: $item.price,
                          format: .currency(code: currencyCode))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .focused(focus, equals: .itemPrice(item.id))
                    .accessibilityIdentifier("expense.receipt.item.price")
            }
            NavigationLink {
                ItemAssigneePicker(itemName: item.name, participants: participants,
                                   assignees: $item.assignees)
            } label: {
                HStack {
                    Image(systemName: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AssigneeSummary.label(item.assignees, in: participants))
                        .font(.caption)
                        .foregroundStyle(item.assignees.isEmpty ? SnappetColor.pomodoro : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("expense.receipt.item.assign")
        }
    }
}

/// Modal text editor for pasting receipt text; hands the parsed result back on "Add".
private struct PasteReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Hands the pasted text back to the caller, which parses it with the chosen type profile.
    let onText: (String) -> Void

    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("expense.receipt.pasteText")
                } header: {
                    Text("Receipt text")
                } footer: {
                    Text("One item per line. Lines ending in a price become items; SUBTOTAL / TAX / TOTAL and instant-savings lines are detected automatically.")
                }
            }
            .navigationTitle("Paste Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add items") {
                        onText(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("expense.receipt.pasteAdd")
                }
            }
        }
    }
}
