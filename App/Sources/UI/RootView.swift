import AuthenticationServices
import LyricsCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: NowPlayingModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.snapshot.isDemo || auth.isSignedIn {
                LyricsScreen()
            } else if !AppConfig.isSpotifyConfigured {
                SetupNeededView()
            } else {
                SignInView()
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase == .active, client: "phone")
            if phase == .active { model.refreshNow() }
            updateIdleTimer()
        }
        .onChange(of: settings.keepScreenAwake) { _, _ in updateIdleTimer() }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && scenePhase == .active
    }
}

struct SetupNeededView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Spotify isn't set up yet", systemImage: "wrench.and.screwdriver")
            } description: {
                Text("Add your Spotify Client ID to Config.xcconfig, then build and run again. SETUP.md has the steps.")
            } actions: {
                Button("Try the demo song") { settings.demoMode = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("tryDemoButton")
            }
            .toolbar { LegalToolbar() }
        }
    }
}

struct SignInView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                        .padding(.top, 40)
                    Text("Lyrics")
                        .font(.largeTitle.bold())
                    Text("Time-synced lyrics for the song playing on Spotify, when LRCLIB has them. On iPhone, and on the CarPlay Dashboard with iOS 26.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Reads what's playing on your Spotify account. Read only.", systemImage: "music.note")
                        Label("Can't change your playback, or see your playlists or library.", systemImage: "lock")
                        Label("Song title and artist are sent to LRCLIB to find lyrics. Nothing else leaves your phone.", systemImage: "magnifyingglass")
                        Label("Works with Spotify Free and Premium.", systemImage: "checkmark.circle")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("signInError")
                    }

                    Button(action: signIn) {
                        HStack {
                            if isSigningIn { ProgressView().tint(.black) }
                            Text("Continue with Spotify").bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.spotifyGreen, in: Capsule())
                        .foregroundStyle(.black)
                    }
                    .disabled(isSigningIn)
                    .accessibilityIdentifier("signInButton")

                    Text("By continuing you agree to the [Terms of Use](carplaylyrics-doc://terms) and [Privacy Policy](carplaylyrics-doc://privacy).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .tint(Color.appAccent)

                    Button("Try the demo song first") { settings.demoMode = true }
                        .font(.callout)
                        .tint(.white)
                        .accessibilityIdentifier("tryDemoButton")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .toolbar { LegalToolbar() }
            .legalLinkHandler()
        }
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await auth.signIn(using: webAuthenticationSession, includeSeek: settings.allowSeeking)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The user closed the sign-in sheet.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

extension Color {
    /// Spotify green, used only for the Spotify sign-in button (Spotify branding guidelines).
    static let spotifyGreen = Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)
    /// The app's own accent, kept distinct from Spotify's brand color.
    static let appAccent = Color(red: 0x5E / 255, green: 0xC8 / 255, blue: 0xFA / 255)
}
