import SwiftUI

struct OnboardingContainerView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var lockManager: LockManager

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("hasSeenModelConsent") private var hasSeenModelConsent = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            if !hasSeenWelcome {
                WelcomeView()
            } else if !hasSeenModelConsent {
                ModelConsentView()
            } else if !authService.isSignedIn && !authService.isGuestMode {
                LoginView()
                    .environmentObject(authService)
            } else if !authService.isGuestMode {
                BiometricSetupView {
                    if let uid = authService.currentUserID {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding_\(uid)")
                    }
                    hasCompletedOnboarding = true
                }
                .environmentObject(lockManager)
                .environmentObject(authService)
            }
        }
        .tint(Color("Primary"))
    }
}

#Preview("Welcome step") {
    OnboardingContainerView()
        .environmentObject(AuthService.shared)
        .environmentObject(LockManager())
        .onAppear {
            UserDefaults.standard.removeObject(forKey: "hasSeenWelcome")
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        }
}

#Preview("Login step") {
    OnboardingContainerView()
        .environmentObject(AuthService.shared)
        .environmentObject(LockManager())
        .onAppear {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        }
}

#Preview("Biometric step") {
    OnboardingContainerView()
        .environmentObject(AuthService.shared)
        .environmentObject(LockManager())
        .onAppear {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
        }
}
