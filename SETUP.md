# Setting up CarPlay Lyrics

You need a Mac with Xcode 16 or later and a Spotify account. For lyrics in a real car
you also need an iPhone on **iOS 26** and a CarPlay car. About 20 minutes in total.

## 1. Generate the Xcode project

The project is described in `project.yml` and generated with XcodeGen (no `.xcodeproj`
is checked in).

```sh
brew install xcodegen
git clone https://github.com/lucascollins-11/CarPlay-Lyrics.git
cd CarPlay-Lyrics
xcodegen generate
open CarPlayLyrics.xcodeproj
```

Run `xcodegen generate` again after pulling changes that add or remove files.

## 2. Try it right away (no accounts)

Pick an iPhone simulator, press Run, and tap **Try the demo song**. The demo plays a
built-in song with original lyrics, so you can see syncing, timing buttons, Settings and
the CarPlay screen without Spotify.

## 3. Create a Spotify app (gets you the Client ID)

1. Go to https://developer.spotify.com/dashboard and log in.
2. **Create app**. Any name and description.
3. **Redirect URI**: add exactly `carplaylyrics://callback`
4. Under "Which API/SDKs are you planning to use?" tick **Web API**.
5. Save, open the app's **Settings**, and copy the **Client ID**.
6. In Development mode Spotify only lets accounts listed under **User Management** use
   the app. Add your own Spotify email there. (If you skip this, the app shows
   "Spotify won't share playback with this app for your account".)

No client secret is needed: the app uses PKCE.

## 4. Fill in `Config.xcconfig`

```
SPOTIFY_CLIENT_ID = <the Client ID from step 3>
DEVELOPMENT_TEAM  = <your Apple Team ID, needed for a real iPhone>
BUNDLE_ID_PREFIX  = com.yourname
PUBLISHER_NAME    = Your Name
SUPPORT_EMAIL     =            (optional, shown in About)
```

Your Team ID is in Xcode > Settings > Accounts (sign in with your Apple ID; a free
account works), or at https://developer.apple.com/account under Membership.

## 5. Install on your iPhone

1. Plug in the iPhone, select it as the run destination, press Run.
2. The first time, approve the developer profile on the phone: Settings > General >
   VPN & Device Management.
3. Sign in with Spotify and play something.

**Free Apple ID vs paid developer account:** with a free account, apps you install
expire after **7 days**; just press Run again to reinstall. A paid account ($99/year)
makes it last a year.

No CarPlay entitlement is needed for anything above. (The project only adds the CarPlay
entitlement to Simulator builds; see step 7.)

## 6. Lyrics in the car: Drive mode

1. Before you drive, open the app and tap **Drive mode** (the car button, top left).
2. Start your music in Spotify as usual (on the phone or the car).
3. On the CarPlay Dashboard the current and next line appear as a Live Activity. They
   also show on the Lock Screen and in the Dynamic Island.

Drive mode keeps the app running in the background with a silent audio session. It
doesn't interrupt or duck Spotify and never becomes the "Now Playing" app. It turns
itself off after 15 minutes with nothing playing, and iOS ends any Live Activity after
8 hours; start it again the next day. If Live Activities are off for the app, turn them
on in Settings > Lyrics.

Glance at the dashboard only when it's safe. Don't read lyrics while driving.

### First drive: test checklist (please report results)

These can only be measured on a real iPhone in a real car. Pass/fail thresholds:

| # | Check | Pass if |
| --- | --- | --- |
| 1 | Start Drive mode, lock the phone, play a song through CarPlay | The Live Activity appears on the CarPlay Dashboard within 10 s |
| 2 | Watch for 5 minutes, comparing the Dashboard line with the iPhone app on a second look | Dashboard line is never more than **1 s** behind the iPhone line, and never misses a line for more than 2 s |
| 3 | Leave the phone locked for 30 minutes of driving | Line keeps updating the whole time (app not suspended) |
| 4 | Take or decline a phone call; let navigation speak a prompt; ask Siri something | Lyrics resume within one line afterwards; Spotify audio is never paused or ducked by this app |
| 5 | Check Control Center / the CarPlay Now Playing screen | Spotify, not Lyrics, is the Now Playing app |
| 6 | Drive through a dead zone | Lyrics keep advancing; "Can't reach Spotify" shows only on the iPhone; catches up within 5 s of signal returning |
| 7 | Pause in Spotify | Dashboard shows "Paused" within 3 s |
| 8 | Skip to the next song | New song's first line within 3 s (or "Finding lyrics…") |
| 9 | Battery over a 1-hour drive | Under ~5% extra drain compared with Spotify alone |

If #2 fails (updates throttled), the fallback is to show the next line in advance; tell
Claude the measured delay.

## 7. The CarPlay app screen (Simulator only)

Apple's CarPlay Developer Guide says audio apps must "never show song lyrics on the
CarPlay screen", so Apple won't grant this app a CarPlay entitlement and the full-screen
CarPlay app can't run in a car. You can still see it in the Simulator: run the app, then
in the Simulator menu choose **I/O > External Displays > CarPlay** and tap **Lyrics**.

## 8. Run the tests

```sh
cd Packages/LyricsCore && swift test          # 116 core tests, seconds
xcodebuild test -project CarPlayLyrics.xcodeproj -scheme CarPlayLyrics \
  -destination 'platform=iOS Simulator,name=iPhone 16'   # app unit + UI tests (demo mode)
```

GitHub Actions runs all of them on every push (`.github/workflows/ci.yml`) and keeps the
UI-test screenshots in the run's `TestResults` artifact.

## App Store privacy label (if it's ever submitted)

- Data used to track you: **None**. Data linked to you: **None**. Data not linked to you:
  **None collected**. Title/artist/album/length are sent to LRCLIB in real time to look
  up lyrics and aren't stored by the developer; Spotify tokens never leave the device
  except to Spotify. See `App/Resources/PrivacyInfo.xcprivacy` for the reasoning.
- Privacy policy URL: the GitHub link to `PRIVACY.md`.
- Note: Drive mode's background audio would not pass review as is.

## Troubleshooting

| What you see | Fix |
| --- | --- |
| "Spotify isn't set up yet" | `SPOTIFY_CLIENT_ID` is still the placeholder in `Config.xcconfig`. |
| Spotify page says "INVALID_CLIENT: Invalid redirect URI" | The Redirect URI must be exactly `carplaylyrics://callback`. |
| "Spotify won't share playback with this app for your account" | Add your Spotify email under **User Management** in the dashboard. |
| "Nothing playing" while music plays | Podcasts, Private Sessions and some local files don't report a song. |
| "No lyrics for this song" | LRCLIB has none. Try **Wrong lyrics?** to search, or add them at lrclib.net. |
| Lyrics consistently early or late | Use − / + under the lyrics (this song) or Settings > Timing (all songs). |
| Drive mode stops by itself | Nothing played for 15 minutes, or the 8-hour Live Activity limit. Start it again. |
