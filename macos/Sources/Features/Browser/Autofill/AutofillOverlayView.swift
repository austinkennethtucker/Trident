import SwiftUI

// MARK: - AutofillOverlayView

/// Full-width overlay positioned at the top of the web content area.
/// Renders whichever autofill UI state is active for the current tab.
struct AutofillOverlayView: View {
    @ObservedObject var controller: BrowserAutofillController
    var availableVaults: [String]

    var body: some View {
        VStack(spacing: 0) {
            if controller.sessionExpired {
                SessionExpiredBanner(controller: controller)
            }

            if controller.showPrompt, !controller.matchingCredentials.isEmpty {
                CredentialPickerView(controller: controller)
            }

            if let code = controller.totpCode {
                TOTPToastView(code: code)
            }

            if controller.showSave {
                SavePromptView(
                    controller: controller,
                    availableVaults: availableVaults
                )
            }

            Spacer()
        }
    }
}

// MARK: - SessionExpiredBanner

private struct SessionExpiredBanner: View {
    @ObservedObject var controller: BrowserAutofillController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundColor(.orange)
            Text("Proton Pass session expired — run `pass-cli login` in a terminal")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Button(action: { controller.sessionExpired = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    Rectangle()
                        .fill(Color.orange)
                        .frame(height: 2),
                    alignment: .bottom
                )
        )
    }
}

// MARK: - CredentialPickerView

private struct CredentialPickerView: View {
    @ObservedObject var controller: BrowserAutofillController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
                Text("Proton Pass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { controller.dismissPrompt() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(controller.matchingCredentials) { credential in
                Button(action: { controller.fill(credential: credential) }) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(credential.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            Text(credential.displayLabel)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if credential.hasTOTP {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .help("Includes TOTP — code will be copied to clipboard")
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if credential.id != controller.matchingCredentials.last?.id {
                    Divider().padding(.horizontal, 12)
                }
            }

            Spacer().frame(height: 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
    }
}

// MARK: - TOTPToastView

private struct TOTPToastView: View {
    let code: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
            Text("TOTP copied to clipboard")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Text("(\(code))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - SavePromptView

private struct SavePromptView: View {
    @ObservedObject var controller: BrowserAutofillController
    let availableVaults: [String]

    @State private var editableTitle: String = ""
    @State private var editableUsername: String = ""
    @State private var selectedVault: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
                Text("Save to Proton Pass?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { controller.dismissSave() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("Login title", text: $editableTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Username / Email")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("username", text: $editableUsername)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            if availableVaults.count > 1 {
                HStack(spacing: 8) {
                    Text("Vault:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: $selectedVault) {
                        ForEach(availableVaults, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
            }

            HStack {
                Spacer()
                Button("Not now") {
                    controller.dismissSave()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

                Button("Save") {
                    controller.saveCredential(
                        title: editableTitle,
                        username: editableUsername,
                        vaultName: selectedVault
                    )
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12))
                .disabled(editableTitle.isEmpty || selectedVault.isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
        .onAppear {
            editableTitle = controller.pendingSaveTitle
            editableUsername = controller.pendingSaveUsername
            selectedVault = availableVaults.first ?? ""
        }
    }
}
