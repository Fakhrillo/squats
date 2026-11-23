import SwiftUI

@main
struct SquatsApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: "figure.strengthtraining.functional")
            if model.ledger.owed > 0 { Text("\(model.ledger.owed)") }
        }
        .menuBarExtraStyle(.window)
    }
}
