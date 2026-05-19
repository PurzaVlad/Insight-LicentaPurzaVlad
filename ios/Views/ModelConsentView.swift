import SwiftUI

struct ModelConsentView: View {
    @AppStorage("hasSeenModelConsent") private var hasSeenModelConsent = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 28) {
                    ZStack {
                        Circle()
                            .fill(Color("Primary").opacity(0.12))
                            .frame(width: 100, height: 100)
                        Image(systemName: "brain")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(Color("Primary"))
                    }

                    VStack(spacing: 10) {
                        Text("On-Device AI")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Insight analizează documentele tale direct pe dispozitiv, fără a trimite date în cloud. Este nevoie de un model AI care va fi descărcat o singură dată.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(Color("Primary"))
                            .font(.system(size: 15, weight: .medium))
                        Text("~1 GB va fi descărcat pe dispozitiv")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 14) {
                    Button {
                        grantConsent()
                    } label: {
                        Text("Descarcă și continuă")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("Primary"))
                    .controlSize(.large)
                    .padding(.horizontal)

                    Button {
                        declineConsent()
                    } label: {
                        Text("Nu acum")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 48)
                }
            }
        }
    }

    private func grantConsent() {
        UserDefaults.standard.set(true, forKey: "modelDownloadConsented")
        NotificationCenter.default.post(name: NSNotification.Name("ModelConsentGranted"), object: nil)
        // Signal JS layer
        DispatchQueue.main.async {
            EdgeAI.shared?.sendEvent(withName: "ModelConsentGranted", body: [:])
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            hasSeenModelConsent = true
        }
    }

    private func declineConsent() {
        UserDefaults.standard.set(true, forKey: "modelDownloadDeclined")
        NotificationCenter.default.post(name: NSNotification.Name("ModelDownloadDeclined"), object: nil)
        withAnimation(.easeInOut(duration: 0.25)) {
            hasSeenModelConsent = true
        }
    }
}

#Preview {
    ModelConsentView()
        .onAppear {
            UserDefaults.standard.removeObject(forKey: "hasSeenModelConsent")
        }
}
