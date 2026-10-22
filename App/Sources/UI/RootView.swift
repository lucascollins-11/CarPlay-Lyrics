import AuthenticationServices
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var model: NowPlayingModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !AppConfig.isSpotifyConfigured {
                SetupNeededView()
            } else if !auth.isSignedIn {
                SignInView()
            } else {
                LyricsScreen()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase != .background, client: "phone")
        }
    }
}

struct SetupNeededView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Spotify isn't set up yet", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("Put your Spotify Client ID in Config.xcconfig, then build and run again. See SETUP.md for the steps.")
        }
    }
}

struct SignInView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("CarPlay Lyrics")
                .font(.largeTitle.bold())
            Text("Synced lyrics for whatever you're playing on Spotify, on your iPhone and in your car.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button {
                signIn()
            } label: {
                HStack {
                    if isSigningIn { ProgressView().tint(.black) }
                    Text("Sign in with Spotify").bold()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.green, in: Capsule())
                .foregroundStyle(.black)
            }
            .disabled(isSigningIn)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await auth.signIn(using: webAuthenticationSession)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The user closed the sign-in sheet.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
