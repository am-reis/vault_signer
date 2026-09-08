import SwiftUI

/// Root router (spec §12 item 2.1): Welcome (no vault open) -> Unlock
/// (vault open, chosen compartment locked) -> KeyList (compartment
/// unlocked). Applies screen-capture blocking (§5.0) to the whole main
/// window, since nearly every state past Welcome shows manifest detail.
struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        Group {
            if state.vaultPath == nil {
                WelcomeView()
            } else if state.unlockedCompartmentId == nil {
                UnlockView()
            } else {
                KeyListView()
            }
        }
        .environmentObject(state)
        .frame(minWidth: 480, minHeight: 420)
        .preventsScreenCapture()
        .alert("common.error_title", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.clearError() } })) {
            Button("common.ok_button") { state.clearError() }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .overlay {
            if state.isBusy {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
