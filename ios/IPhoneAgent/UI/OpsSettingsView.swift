import SwiftUI

/// Settings › Remote management: outbound status, screenshots and whitelisted config for the owner's AI tools.
struct OpsSettingsView: View {
    @ObservedObject var ops: OpsController

    var body: some View {
        List {
            Section {
                TextField("Management URL", text: $ops.endpoint)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                SecureField("Device token", text: $ops.token)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Toggle("Remote management", isOn: $ops.enabled)
                Button("Reconnect") { ops.start() }
                    .disabled(!ops.enabled)
            } header: {
                Text("Connection")
            } footer: {
                Text("Use HTTPS except for a local test server. The token is stored in the Keychain and is never returned by the remote API.")
            }
            Section {
                ValueRow(title: "Status", value: ops.state)
                LabeledContent("Device ID") {
                    Text(verbatim: ops.deviceID).font(.caption).textSelection(.enabled)
                }
            } header: {
                Text("Device")
            }
            Section {
                Text("Allowed: status, diagnostics, current screenshot, model and capture settings, and stopping the agent. Arbitrary HID commands and API keys are not exposed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Remote Management")
        .navigationBarTitleDisplayMode(.inline)
    }
}
