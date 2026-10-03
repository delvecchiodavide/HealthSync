import Foundation
@preconcurrency import GoogleSignIn
import HealthSyncKit
import UIKit

/// Google Sign-In (OAuth 2.0). The SDK stores tokens in the Keychain; the app never sees a password.
@MainActor
@Observable
final class GoogleAuthService {
    static let scopes = [
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/spreadsheets",
    ]

    enum AuthError: LocalizedError {
        case noPresenter, missingScopes

        var errorDescription: String? {
            switch self {
            case .noPresenter: "Couldn't show the Google sign-in screen."
            case .missingScopes: "HealthSync needs access to Google Drive files and Sheets. Please allow both when signing in."
            }
        }
    }

    private(set) var email: String?
    var isSignedIn: Bool { email != nil }

    func restore() async {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            email = nil
            return
        }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            email = Self.hasRequiredScopes(user) ? user.profile?.email : nil
        } catch {
            Log.google.error("Restoring Google sign-in failed: \(error.localizedDescription, privacy: .public)")
            email = nil
        }
    }

    func signIn() async throws {
        guard let presenter = UIApplication.shared.topViewController else { throw AuthError.noPresenter }
        var user = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil,
                                                             additionalScopes: Self.scopes).user
        // The consent screen lets people untick scopes; ask again for anything missing.
        if !Self.hasRequiredScopes(user) {
            user = try await user.addScopes(Self.scopes, presenting: presenter).user
        }
        guard Self.hasRequiredScopes(user) else { throw AuthError.missingScopes }
        email = user.profile?.email
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        email = nil
    }

    /// Signs out and revokes the app's access to the Google account.
    func disconnect() async throws {
        try await GIDSignIn.sharedInstance.disconnect()
        email = nil
    }

    static func hasRequiredScopes(_ user: GIDGoogleUser) -> Bool {
        Set(scopes).isSubset(of: Set(user.grantedScopes ?? []))
    }

    /// A valid access token, refreshed by the SDK when it is close to expiry.
    static func accessToken(forceRefresh: Bool) async throws -> String {
        let signIn = GIDSignIn.sharedInstance
        var user: GIDGoogleUser
        if forceRefresh || signIn.currentUser == nil {
            guard signIn.hasPreviousSignIn() else { throw GoogleAPIError.unauthorized }
            user = try await signIn.restorePreviousSignIn()
        } else {
            user = signIn.currentUser!
        }
        user = try await user.refreshTokensIfNeeded()
        return user.accessToken.tokenString
    }
}

struct GoogleTokenProvider: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String {
        try await GoogleAuthService.accessToken(forceRefresh: forceRefresh)
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
