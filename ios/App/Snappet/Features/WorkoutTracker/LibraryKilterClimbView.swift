import SwiftUI

/// A Kilter climb's page pushed straight from the Library (prompt 188) — the Kilter module's own detail view, given
/// the app-wide session manager and a board controller of its own (it only touches Bluetooth when you connect from
/// the page, like the Kilter module's).
struct LibraryKilterClimbView: View {
    let uuid: String
    @Environment(AppModel.self) private var app
    @State private var board = KilterBoardController()

    var body: some View {
        KilterClimbDetailView(uuid: uuid, board: board, sessions: app.kilterSessions)
    }
}
