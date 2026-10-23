# Setting up CarPlay Lyrics

You need a Mac with Xcode 16 or later and a Spotify account. No Mac? See
[No Mac? Build in GitHub Actions instead](#no-mac-build-in-github-actions-instead). For lyrics in a real car
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
   Since Spotify's February 2026 rules, the account that **owns** the developer app needs
   **Premium**, and a development-mode app allows at most **5 users**. Listeners can be Free.

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

### No Mac? Build in GitHub Actions instead

The **iPhone build** workflow (`.github/workflows/iphone.yml`) builds the app on a GitHub
macOS runner. You skip steps 1, 2 and 4: instead of `Config.xcconfig`, set these under
the repo's **Settings > Secrets and variables > Actions > Variables**:

| Variable | Value |
| --- | --- |
| `SPOTIFY_CLIENT_ID` | the Client ID from step 3 |
| `BUNDLE_ID_PREFIX` | something unique to you, e.g. `com.lucascollins` |
| `PUBLISHER_NAME` | your name (shown in About) |

Then **Actions > iPhone build > Run workflow** and pick one of two ways in:

**A. Sideload (free Apple ID works; needs a Windows PC or Mac once a week)**

1. Run the workflow with **sideload**. When it's green, download the
   `CarPlayLyrics-ipa` artifact from the run page and unzip it to get `CarPlayLyrics.ipa`.
2. On a Windows PC install iTunes (the apple.com version, not the Microsoft Store one) and
   [Sideloadly](https://sideloadly.io). Plug in the iPhone, drag the `.ipa` into
   Sideloadly, enter your Apple ID, press Start.
3. On the iPhone: Settings > Privacy & Security > **Developer Mode** on (it restarts),
   then Settings > General > VPN & Device Management > trust your Apple ID.

With a free Apple ID the install stops opening after **7 days** (the app warns you two
days ahead); run Sideloadly again with the same `.ipa`. A paid account makes it a year.
Free Apple IDs also allow only 3 sideloaded apps at once and 10 new App IDs a week, and
this app uses 2 (the app and its Live Activity widget). If Sideloadly reports an App ID
limit, remove an old sideloaded app or wait a few days.

**B. TestFlight (paid Apple Developer account, $99/year; no computer at all)**

Everything below works from a phone browser or the Apple Developer app.

1. Enroll in the Apple Developer Program (the **Apple Developer** app on iPhone has an
   Enroll button). Note your **Team ID** (developer.apple.com > Account > Membership).
2. In [App Store Connect](https://appstoreconnect.apple.com) > Apps > **+ New App**: iOS,
   any name, bundle ID `<BUNDLE_ID_PREFIX>.carplaylyrics` (if it isn't in the list, add it
   first at developer.apple.com > Identifiers > **+** > App IDs, and also add
   `<BUNDLE_ID_PREFIX>.carplaylyrics.widget`), any SKU.
3. App Store Connect > Users and Access > **Integrations > App Store Connect API** >
   generate a **Team key** with the **Admin** role (cloud signing needs Admin). Download the
   `.p8` file (only possible once) and note the **Key ID** and **Issuer ID**.
4. In the repo add variable `APPLE_TEAM_ID`, and secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`
   and `ASC_KEY_P8` (open the `.p8` file and paste its whole text, including the
   `-----BEGIN PRIVATE KEY-----` lines).
5. Run the workflow with **testflight**. Apple signs the build in the cloud and it goes to
   TestFlight as an internal build (no App Review).
6. Install **TestFlight** from the App Store on the iPhone, signed in with the same Apple ID.
   The build appears there after processing (5 to 30 minutes; App Store Connect may ask
   you to add yourself to an internal testing group the first time).

If the first TestFlight run fails at the export step with a signing-certificate error,
tell Claude: the fix is to sign during the archive step instead (API key plus
`-allowProvisioningUpdates` there too).

TestFlight builds stop opening after **90 days**; run the workflow again for a fresh one.
Internal TestFlight builds are visible only to your own team, nothing is public.

**CarPlay either way:** neither route can include a CarPlay entitlement, and none is
needed. In the car the lyrics come through Drive mode's Live Activity on the CarPlay
Dashboard (step 6), which works the same for sideloaded and TestFlight builds. The
full-screen CarPlay app (step 7) needs Xcode's Simulator, so it can't be seen without a Mac.

## 6. Lyrics in the car: Drive mode

1. Before you drive, open the app and tap **Drive mode** (the car button, top left).
2. Start your music in Spotify as usual (on the phone or the car).
3. On the CarPlay Dashboard the current and next line appear as a Live Activity. They
   also show on the Lock Screen and in the Dynamic Island.

Drive mode keeps the app running in the background with a silent audio session. It
doesn't interrupt or duck Spotify and never becomes the "Now Playing" app. While
CarPlay is connected it never turns itself off (a fuel stop with the car on is fine).
Otherwise it turns itself off 20 minutes after CarPlay disconnects, after 15 minutes with
nothing playing, or when you sign out. iOS ends any Live Activity after 8 hours; start it
again the next day. If Live Activities are off for the app, turn them
on in Settings > Lyrics.

Where it shows in the car (Apple's rules, not this app's):
- Only on the **CarPlay Dashboard**, in the small bottom-right tile it shares with the
  calendar. It doesn't show over full-screen Spotify or Maps.
- Turn on **Live Activities** in the car's CarPlay settings (on the iPhone: Settings >
  General > CarPlay > your car).
- Pressing and holding the tile hides it for that drive.
- Some cars need a firmware update before Live Activities show at all.
- Live Activities can't be tapped in CarPlay; control music from Spotify as usual.
- It needs **iOS 26** on the iPhone. On older iOS the lyrics only show in the app.
- A Focus (Driving Focus, Do Not Disturb) might hide Live Activities on some setups. If the
  tile is missing, check Settings > Focus > Driving, and see check #17 below.

**Whose music is it?** Lyrics follows the Spotify account you signed in with. If someone
else controls the music (a passenger's phone, a Spotify Jam, the car's own Spotify app on
another account), Spotify tells Lyrics about *your* account, not what you can hear. The
lyrics then belong to whatever your account is playing (or "Nothing playing"). The app
shows which account is signed in. Nothing in the app can see another account's session.

**Start it automatically:** in the Shortcuts app, Automation > New > CarPlay > Connects >
Run Immediately, action **Start Drive mode** (from Lyrics). Add a second one for
Disconnects with **Stop Drive mode**. If iOS won't let Lyrics start its background audio
from the automation, Drive mode still shows the tile and asks you to open Lyrics once.

**Timing in the car:** Settings > Timing adjusts the route that's playing now (the car is
remembered separately from Bluetooth headphones). Settings > Drive mode > **Send lines
early** sets how far ahead the Dashboard gets each line (default 0.3 s); raise it if the
tile trails the music.

A sideloaded build expires (7 days with a free Apple ID, 1 year with a paid account).
Lyrics warns two days ahead in the app and with a notification the day before.

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
| 10 | Stop for 10 minutes with the car off (fuel, coffee), then drive on | Lyrics come back on the Dashboard without touching the phone |
| 11 | Park, get out, leave the phone alone | Drive mode ends by itself within ~20 minutes |
| 12 | With the automation set up, get in and connect CarPlay without unlocking the phone | Drive mode starts and the tile appears within 15 s |
| 13 | Ask Siri to play something in another app, then go back to Spotify | The Dashboard line recovers without touching the phone |
| 14 | Unplug and replug CarPlay (or turn the car off and on) mid-song | The Dashboard line recovers without touching the phone |
| 15 | A long drive on a hot day, phone in a mount in the sun | Lyrics keep updating; note if iOS shows a temperature warning |
| 16 | Tune Settings > Drive mode > **Send lines early** until the Dashboard line changes with the singer | Record the value (and the car) in your report |
| 17 | Turn Driving Focus on, then start Drive mode | The tile still appears on the Dashboard; if it doesn't, record which Focus settings hid it |
| 18 | Note cellular data used by Lyrics over a 1-hour drive (Settings > Cellular, reset statistics first) | Under ~10 MB (estimate below); report the number |

**Mobile data (estimate, to be confirmed by row 18):** while a song plays and lyrics are on
screen or Drive mode is on, the app asks Spotify what's playing every 1.5 s, about 2,400
times an hour. Each answer is roughly 3–8 KB of JSON (most of it the song's list of
markets), sent compressed, so about 1.5–3 KB each with headers. That is roughly **4–8 MB
an hour**, plus a few KB per new song for lyrics. Paused, it asks every 5 s; with nothing
showing lyrics it doesn't ask at all. When the phone is hot or in Low Power Mode it slows to
every 3–5 s.

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
| Lyrics consistently early or late | Use − / + under the lyrics (this song) or Settings > Timing (all songs on the current route: car, Bluetooth, speaker…). |
| Nothing shows on the CarPlay screen | Look at the **Dashboard**, not the Spotify screen; check Live Activities is on in CarPlay settings; check the tile wasn't hidden with a long press. |
| Drive mode stops by itself | 20 minutes after CarPlay disconnected, nothing played for 15 minutes away from the car, you signed out, or the 8-hour Live Activity limit. Start it again. |
