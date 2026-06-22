import SwiftUI
import LocalAuthentication
import Security

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @EnvironmentObject private var authService: AuthService
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage("useFaceID") private var useFaceID = false
    @AppStorage("hasSeenModelConsent") private var hasSeenModelConsent = false
    @AppStorage("useLibreOfficeEngine") private var useLibreOfficeEngine = false
    @State private var isFaceIDAvailable = false
    @State private var faceIDStatusText = ""
    @State private var showingFaceIDError = false
    @State private var faceIDErrorMessage = ""

    @State private var showingPasscodeSheet = false
    @State private var passcodeSet = false
    @State private var passcode = ""
    @State private var confirmPasscode = ""
    @State private var showingPasscodeError = false
    @State private var passcodeErrorMessage = ""

    @State private var showingDeleteAccountConfirm = false
    @State private var showingWithdrawConsentConfirm = false
    @State private var isDeletingAccount = false
    @State private var accountErrorMessage: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Picker("Theme", selection: $appThemeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section(header: Text("Unlock Method")) {
                    HStack {
                        Text("Passcode")
                        Spacer()
                        Text(passcodeSet ? "Set" : "Not set")
                            .foregroundColor(.secondary)
                    }

                    Button(passcodeSet ? "Change Passcode" : "Set Passcode") {
                        passcode = ""
                        confirmPasscode = ""
                        showingPasscodeSheet = true
                    }

                    if passcodeSet {
                        Button("Remove Passcode", role: .destructive) {
                            if KeychainService.deletePasscode() {
                                passcodeSet = false
                                useFaceID = false
                            }
                        }
                    }

                    if isFaceIDAvailable {
                        Toggle(isOn: faceIDToggleBinding) {
                            Text("Face ID")
                        }
                        .disabled(!passcodeSet)

                        if !passcodeSet {
                            Text("Set a passcode first to enable Face ID.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else if !faceIDStatusText.isEmpty {
                        Text(faceIDStatusText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Account")) {
                    if authService.isGuestMode {
                        Text("Guest mode — no account")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button("Sign In / Create Account") {
                            authService.exitGuestMode()
                        }
                    } else {
                        if let email = authService.currentUserEmail {
                            Text(email)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Button("Sign Out", role: .destructive) {
                            authService.signOut()
                        }
                        if let errMsg = accountErrorMessage {
                            Text(errMsg)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                        Button(role: .destructive) {
                            showingDeleteAccountConfirm = true
                        } label: {
                            if isDeletingAccount {
                                HStack {
                                    ProgressView()
                                    Text("Deleting…")
                                }
                            } else {
                                Text("Delete Account Permanently")
                            }
                        }
                        .disabled(isDeletingAccount)
                    }
                }

                Section(header: Text("Conversion")) {
                    Toggle(isOn: $useLibreOfficeEngine) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Privacy-preserving mode")
                            Text("Files are processed on our server only — no data sent to third-party services.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Color("Primary"))
                }

                Section(header: Text("Privacy")) {
                    Button(role: .destructive) {
                        showingWithdrawConsentConfirm = true
                    } label: {
                        Label("Withdraw AI Model Consent", systemImage: "hand.raised")
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        if let url = URL(string: "mailto:contact.insightapp@gmail.com?subject=Insight%20Support") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Contact Support", systemImage: "envelope")
                    }

                    if let privacyURL = URL(string: "https://purzavlad.github.io/insight-legal/privacy") {
                        Link(destination: privacyURL) {
                            Label("Privacy Policy", systemImage: "hand.raised.fill")
                        }
                    }

                    if let termsURL = URL(string: "https://purzavlad.github.io/insight-legal/terms") {
                        Link(destination: termsURL) {
                            Label("Terms of Service", systemImage: "doc.text")
                        }
                    }
                }

                if let message = documentManager.vaultUnavailableMessage {
                    Section(header: Text("Vault")) {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.red)
                        Button("Reset Local Vault", role: .destructive) {
                            documentManager.resetLocalVault()
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            refreshFaceIDAvailability()
            passcodeSet = KeychainService.passcodeExists()
        }
        .alert("Face ID Error", isPresented: $showingFaceIDError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(faceIDErrorMessage)
        }
        .alert("Passcode Error", isPresented: $showingPasscodeError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(passcodeErrorMessage)
        }
        .alert("Delete Account", isPresented: $showingDeleteAccountConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete your account and all associated data. This action cannot be undone.")
        }
        .alert("Withdraw Consent", isPresented: $showingWithdrawConsentConfirm) {
            Button("Withdraw", role: .destructive) {
                withdrawConsent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The AI model consent will be reset. You will be asked again on next launch. Your account will be signed out.")
        }
        .sheet(isPresented: $showingPasscodeSheet) {
            NavigationStack {
                Form {
                    SecureField("New 6-digit passcode", text: $passcode)
                        .keyboardType(.numberPad)
                    SecureField("Confirm passcode", text: $confirmPasscode)
                        .keyboardType(.numberPad)
                }
                .navigationTitle(passcodeSet ? "Change Passcode" : "Set Passcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            savePasscode()
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            showingPasscodeSheet = false
                        }
                    }
                }
            }
        }
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: appThemeRaw) ?? .light
    }

    private var faceIDToggleBinding: Binding<Bool> {
        Binding(
            get: { useFaceID },
            set: { newValue in
                if newValue {
                    enableFaceID()
                } else {
                    useFaceID = false
                }
            }
        )
    }

    private func refreshFaceIDAvailability() {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        isFaceIDAvailable = canEvaluate && context.biometryType == .faceID

        if !isFaceIDAvailable {
            useFaceID = false
            if let error = error {
                faceIDStatusText = error.localizedDescription
            } else {
                faceIDStatusText = "Face ID is not available on this device."
            }
        } else {
            faceIDStatusText = ""
        }
    }

    private func enableFaceID() {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              context.biometryType == .faceID else {
            refreshFaceIDAvailability()
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Enable Face ID to unlock Insight.") { success, authError in
            DispatchQueue.main.async {
                if success {
                    useFaceID = true
                } else {
                    useFaceID = false
                    faceIDErrorMessage = authError?.localizedDescription ?? "Face ID could not be enabled."
                    showingFaceIDError = true
                }
            }
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        accountErrorMessage = nil
        do {
            try await authService.deleteAccount()
        } catch {
            accountErrorMessage = error.localizedDescription
        }
        isDeletingAccount = false
    }

    private func withdrawConsent() {
        UserDefaults.standard.removeObject(forKey: "modelDownloadConsented")
        UserDefaults.standard.removeObject(forKey: "modelDownloadDeclined")
        UserDefaults.standard.removeObject(forKey: "modelReady")
        hasSeenModelConsent = false
        authService.signOut()
    }

    private func savePasscode() {
        let trimmed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else {
            passcodeErrorMessage = "Passcode must be exactly 6 digits."
            showingPasscodeError = true
            return
        }
        guard trimmed == confirmPasscode else {
            passcodeErrorMessage = "Passcodes do not match."
            showingPasscodeError = true
            return
        }

        if KeychainService.setPasscode(trimmed) {
            passcodeSet = true
            showingPasscodeSheet = false
        } else {
            passcodeErrorMessage = "Failed to save passcode."
            showingPasscodeError = true
        }
    }
}
