import SwiftUI

/// §5.1 "View list": label, resource, key type, purpose, last used.
/// Never shows raw key material. Screen-capture-blocked (§5.0: manifest
/// detail).
struct KeyListView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCreateKey = false
    @State private var showingSettings = false
    @State private var showingExport = false
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            Group {
                if state.keys.isEmpty {
                    // `ContentUnavailableView` needs macOS 14+; this
                    // project's floor is macOS 13 (spec §12 item 0.2), so
                    // build the equivalent empty state by hand.
                    VStack(spacing: 12) {
                        Image(systemName: "key").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Keys Yet").font(.headline)
                        Text("Create your first key to start signing.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(state.keys, id: \.keyId) { key in
                        NavigationLink(value: key.keyId) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.label).font(.headline)
                                Text("\(key.resource.isEmpty ? "(no resource)" : key.resource) · \(keyTypeLabel(key.keyType)) · \(purposeLabel(key.purpose))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { keyId in
                if let key = state.keys.first(where: { $0.keyId == keyId }) {
                    KeyDetailView(key: key)
                }
            }
            .navigationTitle(currentCompartmentLabel)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingCreateKey = true } label: { Label("New Key", systemImage: "plus") }
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Export Packet…") { showingExport = true }
                        Button("Import Packet…") { showingImport = true }
                    } label: {
                        Label("Import/Export", systemImage: "tray.and.arrow.up")
                    }
                    // Without this, VoiceOver/Accessibility-tree tools
                    // read this control as "Outbox" (inferred from the
                    // SF Symbol) instead of the actual label above —
                    // found while UI-testing 2.3/2.4 via the
                    // Accessibility API (see the macOS README).
                    .accessibilityLabel("Import/Export")
                }
                ToolbarItem(placement: .automatic) {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Lock") { state.lockAll() }
                }
            }
        }
        .preventsScreenCapture()
        .sheet(isPresented: $showingCreateKey) {
            CreateKeyView().environmentObject(state)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingExport) {
            ExportPacketView().environmentObject(state)
        }
        .sheet(isPresented: $showingImport) {
            ImportPacketView().environmentObject(state)
        }
        .onAppear { state.refreshKeys() }
    }

    private var currentCompartmentLabel: String {
        state.compartments.first(where: { $0.compartmentId == state.unlockedCompartmentId })?.label ?? "Keys"
    }

    private func keyTypeLabel(_ type: FacadeKeyType) -> String {
        switch type {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        }
    }

    private func purposeLabel(_ purpose: FacadePurpose) -> String {
        switch purpose {
        case .fido2: return "FIDO2"
        case .customSigning: return "Custom signing"
        case .both: return "FIDO2 + custom signing"
        }
    }
}
