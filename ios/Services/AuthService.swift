import Foundation
import FirebaseAuth
import GoogleSignIn
import AuthenticationServices
import CryptoKit

final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isSignedIn: Bool = false
    @Published var currentUserEmail: String? = nil
    /// True after the first Firebase auth state callback fires (persisted user restored or confirmed absent)
    @Published var authStateLoaded: Bool = false
    @Published var isGuestMode: Bool = false
    /// Set to true when a guest signs in/up, so TabContainerView can offer a data-transfer dialog.
    @Published var pendingGuestTransfer: Bool = false

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    private init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.isSignedIn = user != nil
                self?.currentUserEmail = user?.email
                self?.authStateLoaded = true
                if user != nil { self?.isGuestMode = false }
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    var currentUserID: String? {
        Auth.auth().currentUser?.uid
    }

    func signIn(email: String, password: String) async throws {
        if isGuestMode { pendingGuestTransfer = true }
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        if isGuestMode { pendingGuestTransfer = true }
        try await Auth.auth().createUser(withEmail: email, password: password)
    }

    func signInWithGoogle(presenting viewController: UIViewController) async throws {
        if isGuestMode { pendingGuestTransfer = true }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingGoogleToken
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await Auth.auth().signIn(with: credential)
    }

    // MARK: - Sign in with Apple

    // Stored so the delegate isn't deallocated mid-flow
    private var appleSignInCoordinator: AppleSignInCoordinator?

    func signInWithApple(presenting anchor: ASPresentationAnchor) async throws {
        if isGuestMode { pendingGuestTransfer = true }
        let coordinator = AppleSignInCoordinator()
        appleSignInCoordinator = coordinator
        defer { appleSignInCoordinator = nil }
        let credential = try await coordinator.signIn(anchor: anchor)
        try await Auth.auth().signIn(with: credential)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isGuestMode = false
        pendingGuestTransfer = false
        do {
            try Auth.auth().signOut()
        } catch {
            // Firebase signOut failed (e.g. Keychain unavailable during lockout).
            // Manually clear published state so the lockout protection is not
            // bypassed — the app treats the user as signed out regardless.
            DispatchQueue.main.async {
                self.isSignedIn = false
                self.currentUserEmail = nil
            }
        }
    }

    func continueAsGuest() {
        isGuestMode = true
    }

    func exitGuestMode() {
        isGuestMode = false
    }

    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthServiceError.notSignedIn
        }
        try await user.delete()
    }

    func getIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthServiceError.notSignedIn
        }
        return try await user.getIDToken(forcingRefresh: false)
    }

    /// Forces a token refresh from Firebase, then calls completion.
    /// Use before retrying a request that failed with 401 (token may have expired).
    func forceTokenRefresh(completion: @escaping () -> Void) {
        guard let user = Auth.auth().currentUser else {
            completion()
            return
        }
        user.getIDTokenForcingRefresh(true) { _, _ in
            completion()
        }
    }

    /// Synchronous token fetch for use on background threads.
    func currentIDTokenSync() -> String {
        var result = ""
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let user = Auth.auth().currentUser else {
                semaphore.signal()
                return
            }
            user.getIDTokenForcingRefresh(false) { token, _ in
                result = token ?? ""
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }
}

enum AuthServiceError: LocalizedError {
    case notSignedIn
    case missingGoogleToken
    case missingAppleToken
    case appleSignInCancelled

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "No user is currently signed in."
        case .missingGoogleToken: return "Google sign-in failed: missing token."
        case .missingAppleToken: return "Apple sign-in failed: missing token."
        case .appleSignInCancelled: return "Apple sign-in was cancelled."
        }
    }
}

// MARK: - Apple Sign-In coordinator

private final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<OAuthCredential, Error>?
    private var currentNonce: String?
    private weak var anchor: ASPresentationAnchor?

    func signIn(anchor: ASPresentationAnchor) async throws -> OAuthCredential {
        self.anchor = anchor
        let nonce = randomNonceString()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    // MARK: ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = appleIDCredential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8),
              let nonce = currentNonce else {
            continuation?.resume(throwing: AuthServiceError.missingAppleToken)
            continuation = nil
            return
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: tokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let asError = error as? ASAuthorizationError
        if asError?.code == .canceled {
            continuation?.resume(throwing: AuthServiceError.appleSignInCancelled)
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    // MARK: ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? UIWindow()
    }

    // MARK: Nonce helpers

    private func randomNonceString(length: Int = 32) -> String {
        var result = ""
        var remaining = length
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            bytes.forEach { byte in
                if remaining == 0 { return }
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
