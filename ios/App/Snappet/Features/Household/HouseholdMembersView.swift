import SwiftUI

/// The Household section (wireframe frame 5): names, members, the phones you sync with and when,
/// Sync now, invite and join.
struct HouseholdMembersView: View {
    let store: HouseholdStore
    let service: HouseholdPeerService
    let invite: () -> Void
    let join: () -> Void

    @State private var householdName = ""
    @State private var myName = ""

    var body: some View {
        List {
            if service.localNetworkDenied {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Local Network is off for Snappet", systemImage: "wifi.exclamationmark")
                            .snappetTitle().foregroundStyle(SnappetColor.perfHard)
                        Text("Phones can't find each other until it's on: Settings › Privacy & Security › Local Network › Snappet.")
                            .snappetDetail()
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(SnappetWidePrimaryStyle())
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("household.localNetworkDenied")
                }
            }
            Section("Names") {
                LabeledContent("Household") {
                    TextField("Household name", text: $householdName)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { store.rename(householdName) }
                        .accessibilityIdentifier("household.members.householdName")
                }
                LabeledContent("You") {
                    TextField("Your name", text: $myName)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { store.setMyName(myName) }
                        .accessibilityIdentifier("household.members.myName")
                }
            }

            Section {
                ForEach(store.board.members) { m in
                    HStack {
                        MemberAvatar(name: m.id == store.me ? store.myName : m.name, id: m.id)
                        Text(m.id == store.me ? "\(store.myName) (you)" : m.name)
                        Spacer()
                    }
                }
            } header: {
                Text("Members · \(store.board.members.count)")
            }

            if !store.peers.isEmpty {
                Section {
                    ForEach(store.peers) { peer in
                        HStack(spacing: 10) {
                            MemberAvatar(name: peer.name, id: peer.memberID ?? peer.deviceID)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(peer.name.isEmpty ? "A phone" : peer.name).font(.system(size: 15, weight: .medium))
                                    Text(peer.platform == "ios" ? "iPhone" : peer.platform.capitalized)
                                        .font(.system(size: 10)).foregroundStyle(SnappetColor.textSecondary)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SnappetColor.hairline))
                                }
                                Text(service.nearby[peer.deviceID] != nil
                                     ? "Nearby · synced \(peer.lastSyncedAt.formatted(.relative(presentation: .named)))"
                                     : "Last synced \(peer.lastSyncedAt.formatted(.relative(presentation: .named)))")
                                    .snappetDetail()
                            }
                            Spacer()
                            // Green = online right now (a meaning colour, not the accent).
                            Circle().fill(service.nearby[peer.deviceID] != nil ? SnappetColor.perfFresh : SnappetColor.hairline)
                                .frame(width: 9, height: 9)
                        }
                    }
                    Button {
                        service.syncNow()
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if service.isSyncing { ProgressView().controlSize(.small) }
                        }
                    }
                    .accessibilityIdentifier("household.members.syncNow")
                } header: {
                    Text("Phones")
                } footer: {
                    Text("Changes travel phone to phone when you're on the same Wi-Fi with Snappet open. If Jo syncs with Sam and Sam syncs with you, you get Jo's changes too.")
                }
            }

            Section {
                Button(action: invite) { Label("Invite someone", systemImage: "person.badge.plus") }
                    .accessibilityIdentifier("household.members.invite")
                Button(action: join) { Label("Join a household", systemImage: "house.and.flag") }
                    .accessibilityIdentifier("household.members.join")
            } footer: {
                Text("Nothing goes to a server: no account, no cloud.")
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            householdName = store.displayName
            myName = store.myName
        }
        .onChange(of: store.displayName) { _, v in householdName = v }
    }
}

struct MemberAvatar: View {
    let name: String
    let id: UUID

    var body: some View {
        let hues: [Color] = [SnappetColor.workout, SnappetColor.budget, SnappetColor.journal, SnappetColor.household,
                             SnappetColor.wardrobe, SnappetColor.tip]
        let tint = hues[Int(id.uuid.0) % hues.count]   // stable per member
        Text(String(name.first ?? "?").uppercased())
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(tint, in: Circle())
            .foregroundStyle(.black.opacity(0.75))
            .accessibilityHidden(true)
    }
}

/// Today's sync pill (frames 1 and 6).
struct HouseholdSyncPill: View {
    let store: HouseholdStore
    let service: HouseholdPeerService

    var body: some View {
        let waiting = store.changesWaiting
        let (text, tint): (String, Color) = {
            if service.isSyncing { return ("Syncing…", SnappetColor.brand) }
            if waiting > 0 { return ("\(waiting) change\(waiting == 1 ? "" : "s") waiting", SnappetColor.perfModerate) }
            let phones = store.peers.count + 1
            if let last = store.lastSyncedAt {
                return ("\(phones) phones · synced \(last.formatted(.relative(presentation: .named)))", SnappetColor.perfFresh)
            }
            return ("Not synced yet", SnappetColor.textSecondary)
        }()
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.35), in: Capsule())
        .accessibilityIdentifier("household.syncPill")
    }
}
