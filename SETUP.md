# Setting up CarPlay Lyrics

You need a Mac with Xcode 15 or later (Xcode 16 recommended) and a Spotify account.
Everything below takes about 15 minutes, except the CarPlay entitlement in step 5,
which is Apple's call and can take days or be refused.

## 1. Generate the Xcode project

The project is described in `project.yml` and generated with XcodeGen, so there is
no `.xcodeproj` checked in.

```sh
brew install xcodegen
cd CarPlayLyrics
xcodegen generate
open CarPlayLyrics.xcodeproj
```

Run `xcodegen generate` again whenever you add or remove files.

## 2. Create a Spotify app (gets you the Client ID)

1. Go to https://developer.spotify.com/dashboard and log in.
2. **Create app**. Any name and description.
3. **Redirect URI**: add exactly `carplaylyrics://callback`
4. Under "Which API/SDKs are you planning to use?" tick **Web API**.
5. Save, open the app's **Settings**, and copy the **Client ID**.
6. While the app is in Development mode, Spotify only lets accounts you list under
   **User Management** sign in. Add your own Spotify email there (and anyone else's
   who will use it).

No client secret is needed: the app uses PKCE.

## 3. Fill in `Config.xcconfig`

```
SPOTIFY_CLIENT_ID = <the Client ID from step 2>
DEVELOPMENT_TEAM = <your Apple Team ID, needed only for a real iPhone>
BUNDLE_ID_PREFIX = com.yourname
```

Your Team ID is in Xcode > Settings > Accounts, or at
https://developer.apple.com/account under Membership.

## 4. Try it in the Simulator (no Apple approval needed)

1. Pick an iPhone simulator and press Run.
2. Tap **Sign in with Spotify** and log in.
3. Start playing something on Spotify on any device (your phone, laptop, or the web player).
   The lyrics appear on the simulator within a few seconds.
4. Open the CarPlay screen: in the Simulator menu choose
   **I/O > External Displays > CarPlay**. Tap the **Lyrics** app icon on the CarPlay home screen.

If the timing is a little off, use the − / + buttons (on the phone or in the CarPlay
top bar). **+** shows lyrics earlier, **−** later. The setting is remembered.

You can also test with Apple's standalone **CarPlay Simulator** (Additional Tools for
Xcode, from https://developer.apple.com/download/all/) with a real iPhone plugged in,
once step 5 is done.

## 5. Running it in a real car

CarPlay apps only appear in a car if the app's provisioning profile includes a CarPlay
entitlement, and Apple grants those per team on request.

1. Request it at https://developer.apple.com/contact/carplay/ . This project uses the
   **Audio** category (`com.apple.developer.carplay-audio`).
2. Once Apple approves, in https://developer.apple.com/account go to
   Certificates, Identifiers & Profiles, create (or regenerate) a provisioning profile
   for your bundle ID and add the CarPlay Audio entitlement to it.
3. In Xcode, select that profile (or let automatic signing pick it up), set
   `DEVELOPMENT_TEAM`, and run on your iPhone.
4. Plug the iPhone into the car (or connect wirelessly). The **Lyrics** app shows up on
   the CarPlay home screen.

**Be aware:** Apple only grants CarPlay entitlements for specific categories (audio,
navigation, communication, and so on), and a screen of scrolling text is exactly the
kind of driver distraction its CarPlay guidelines are written to prevent. Apple may
refuse the request. The iPhone app works either way, and the CarPlay screen always
works in the Simulator.

## 6. Run the unit tests

```sh
cd Packages/LyricsCore
swift test
```

The same tests and a Simulator build run in GitHub Actions (`.github/workflows/ci.yml`)
once the project is pushed to GitHub.

## Troubleshooting

| What you see | Fix |
| --- | --- |
| "Spotify isn't set up yet" | `SPOTIFY_CLIENT_ID` is still the placeholder in `Config.xcconfig`. |
| Spotify page says "INVALID_CLIENT: Invalid redirect URI" | The Redirect URI in the dashboard must be exactly `carplaylyrics://callback`. |
| Sign-in succeeds but nothing ever plays | Your Spotify account isn't in the app's **User Management** list, or Spotify isn't playing on any device. |
| "No lyrics found" | LRCLIB has no entry for the song. Anyone can add lyrics at https://lrclib.net. |
| Lyrics consistently early or late | Use the timing buttons. Bluetooth and car audio often add 0.2–0.5 s of delay. |
