import SwiftUI

/// Joining a household (household prompt 02): scan or paste an invite → confirm → connect → done.
/// The confirm step names what happens to a solo board you already have.
struct HouseholdJoinSheet: View {
    let service: HouseholdPeerService
    let store: HouseholdStore
    /// Set when arriving from a scanned / opened link; nil starts at the scanner.
    @State var invite: HouseholdInvite?

    @Environment(\.dismiss) private var dismiss
    @State private var myName = ""
    @State private var bringChores = true
    @State private var pasted = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Group {
                switch service.joinState {
                case .idle, .failed:
                    if let invite { confirm(invite) } else { start }
                case .searching(let name):
                    progress(name)
                case .joined(let name):
                    done(name)
                }
            }
            .navigationTitle("Join a household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isJoined ? "Done" : "Cancel") {
                        service.resetJoin()
                        dismiss()
                    }
                    .accessibilityIdentifier("household.join.close")
                }
            }
        }
        .onAppear {
            if myName.isEmpty, store.myName != "You" { myName = store.myName }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                SnappetScannerView(prompt: "Point at the invite code on the other phone",
                                   foreignHint: "That isn't a household invite.",
                                   decode: { HouseholdInvite(string: $0) },
                                   onScan: { scanned in
                                       invite = scanned
                                       scanning = false
                                   })
                .padding()
                .navigationTitle("Scan invite")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
    }

    private var isJoined: Bool { if case .joined = service.joinState { return true } else { return false } }

    private var start: some View {
        Form {
            Section {
                Button { scanning = true } label: { Label("Scan an invite code", systemImage: "qrcode.viewfinder") }
                    .accessibilityIdentifier("household.join.scan")
            } footer: {
                Text("On the other phone: Household → Household → Invite someone.")
            }
            Section("Or paste an invite link") {
                TextField("snappet://household/join?…", text: $pasted)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("household.join.link")
                Button("Use link") { invite = HouseholdInvite(string: pasted) }
                    .disabled(HouseholdInvite(string: pasted) == nil)
                    .accessibilityIdentifier("household.join.useLink")
            }
        }
    }

    private func confirm(_ invite: HouseholdInvite) -> some View {
        let chores = store.board.activeChores.count
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Join \(invite.name.isEmpty ? "this household" : invite.name)?").font(.title3.weight(.bold))
                    Text("You'll share one chore board, and work towards the same goal.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if case .failed(let message) = service.joinState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SnappetColor.perfHard)
                        .accessibilityIdentifier("household.join.error")
                }
            }
            Section("Your name in the household") {
                TextField("Your name", text: $myName)
                    .accessibilityIdentifier("household.join.name")
            }
            if chores > 0 {
                Section {
                    Toggle("Bring my \(chores) chore\(chores == 1 ? "" : "s")", isOn: $bringChores)
                } footer: {
                    Text("Your current board is kept on this phone, along with the XP it earned.")
                }
            }
            Section {
                Button {
                    service.join(invite, myName: myName, bringChores: bringChores)
                } label: {
                    Text("Join").frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.household)
                .disabled(myName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("household.join.confirm")
            } footer: {
                Text("Keep both phones on the same Wi-Fi with Snappet open.")
            }
        }
    }

    private func progress(_ name: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Looking for \(name.isEmpty ? "the household" : name) on this Wi-Fi…").font(.headline)
            Text("Keep the invite code open on the other phone.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func done(_ name: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill").font(.system(size: 54)).foregroundStyle(SnappetColor.household)
            Text("You're in \(name)").font(.title3.weight(.bold))
                .accessibilityIdentifier("household.join.done")
            Text("Your board now matches everyone else's.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
