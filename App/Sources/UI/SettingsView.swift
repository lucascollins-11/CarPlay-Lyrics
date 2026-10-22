import AuthenticationServices
import LyricsCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var model: NowPlayingModel
    @EnvironmentObject private var driveMode: DriveModeController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var cachedSongs = 0
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var deleted = false
    @State private var authMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                driveSection
                timingSection
                displaySection
                spotifySection
                Section {
                    Toggle("Demo song", isOn: $settings.demoMode)
                        .accessibilityIdentifier("demoToggle")
                } footer: {
                    Text("Plays a built-in song with original lyrics, so you can try the app without Spotify.")
                }
                storageSection
                privacySection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsDone")
                }
            }
            .task { cachedSongs = await model.cachedSongCount() }
            .legalLinkHandler()
            .alert("Your data was deleted", isPresented: $deleted) {
                Link("Open Spotify account settings", destination: AppConfig.spotifyAppsURL)
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("To also remove this app's access to your Spotify account, go to spotify.com/account/apps and remove it there.")
            }
        }
    }

    // MARK: Sections

    private var driveSection: some View {
        Section {
            Button {
                driveMode.isRunning ? driveMode.stop() : driveMode.start()
            } label: {
                Label(driveMode.isRunning ? "Stop Drive mode" : "Start Drive mode", systemImage: "car")
            }
            .accessibilityIdentifier("settingsDriveMode")
            if let message = driveMode.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Drive mode")
        } footer: {
            Text("Shows the current line as a Live Activity on the Lock Screen and in the Dynamic Island, and on the CarPlay Dashboard with iOS 26. Start it before you drive. It keeps the app running in the background with a silent audio session (Spotify keeps playing), never stops by itself while connected to CarPlay, stops 20 minutes after CarPlay disconnects or after 15 minutes with nothing playing, and iOS ends it after 8 hours. Glance only when it is safe.")
        }
    }

    private var timingSection: some View {
        Section {
            Stepper(value: $settings.globalOffset, in: -3...3, step: 0.05) {
                LabeledContent("All songs", value: settings.globalOffset == 0 ? "0.00 s" : String(format: "%+.2f s", settings.globalOffset))
            }
            .accessibilityIdentifier("globalOffsetStepper")
            if !settings.trackOffsets.isEmpty {
                Button("Reset timing for \(settings.trackOffsets.count) song\(settings.trackOffsets.count == 1 ? "" : "s")") {
                    settings.trackOffsets = [:]
                    model.resetTrackOffset()
                }
            }
        } header: {
            Text("Timing")
        } footer: {
            Text("Positive values show lyrics earlier. Car stereos and Bluetooth often add 0.2–0.5 s of delay. Adjust single songs with the − and + buttons under the lyrics.")
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Picker("Lyrics size", selection: $settings.lyricsTextSize) {
                ForEach(AppSettings.TextSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            Toggle("Keep screen on", isOn: $settings.keepScreenAwake)
        }
    }

    private var spotifySection: some View {
        Section {
            if auth.isSignedIn {
                LabeledContent("Spotify", value: "Connected")
                Toggle("Tap a line to jump there", isOn: Binding(
                    get: { settings.allowSeeking && auth.canSeek },
                    set: { setSeeking($0) }
                ))
                if let authMessage {
                    Text(authMessage).font(.footnote).foregroundStyle(.orange)
                }
                Button("Sign out of Spotify", role: .destructive) { confirmSignOut = true }
                    .accessibilityIdentifier("signOutButton")
                    .confirmationDialog("Sign out of Spotify?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign out", role: .destructive) { auth.signOut() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Lyrics already saved on this iPhone stay until you clear them.")
                    }
            } else {
                LabeledContent("Spotify", value: AppConfig.isSpotifyConfigured ? "Not connected" : "Not set up")
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Jumping to a line needs Spotify Premium and an extra permission to control playback. You'll be asked to approve it when you turn this on.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Saved lyrics", value: "\(cachedSongs) song\(cachedSongs == 1 ? "" : "s")")
            Button("Clear saved lyrics") {
                Task {
                    await model.clearLyricsCache()
                    cachedSongs = await model.cachedSongCount()
                }
            }
            .disabled(cachedSongs == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text("Lyrics are saved on this iPhone so songs you replay load instantly, even offline.")
        }
    }

    private var privacySection: some View {
        Section("Privacy & about") {
            NavigationLink("Privacy Policy") { LegalDocumentView(document: .privacy) }
            NavigationLink("Terms of Use") { LegalDocumentView(document: .terms) }
            NavigationLink("About") { AboutView() }
                .accessibilityIdentifier("aboutLink")
            Button("Delete my data", role: .destructive) { confirmDelete = true }
                .accessibilityIdentifier("deleteDataButton")
                .confirmationDialog("Delete all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete my data", role: .destructive) {
                        Task {
                            driveMode.stop()
                            await model.deleteAllData()
                            cachedSongs = 0
                            deleted = true
                        }
                    }
                    .accessibilityIdentifier("confirmDeleteData")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Signs out of Spotify, deletes saved lyrics and all settings, and ends Drive mode.")
                }
        }
    }

    private func setSeeking(_ enabled: Bool) {
        authMessage = nil
        guard enabled else {
            settings.allowSeeking = false
            return
        }
        if auth.canSeek {
            settings.allowSeeking = true
            return
        }
        // Ask Spotify for the extra permission.
        Task {
            do {
                try await auth.signIn(using: webAuthenticationSession, includeSeek: true)
                settings.allowSeeking = auth.canSeek
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                settings.allowSeeking = false
            } catch {
                settings.allowSeeking = false
                authMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
