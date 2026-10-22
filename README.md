# CarPlay Lyrics

An iPhone app that shows time-synced lyrics for the song playing on your Spotify
account, when [LRCLIB](https://lrclib.net) has them, and puts the current line on the
**CarPlay Dashboard** with iOS 26.

- Sign in once with Spotify (Free or Premium listeners). Read-only by default. Since
  February 2026 the owner of the Spotify developer app must have **Premium**, and a
  development-mode app allows up to 5 users.
- Follows the song and highlights the line being sung. Works with Spotify playing on
  any device: the phone, the car, a speaker.
- **Drive mode** shows the current and next line as a Live Activity on the Lock Screen,
  in the Dynamic Island and on the CarPlay Dashboard (iOS 26+).
- Per-song timing nudges, plus a timing offset per audio route (car, Bluetooth, AirPlay,
  wired, speaker), and a Dashboard lead so lines land on time in the car.
- Shortcuts: Start/Stop Drive mode, Lyrics earlier/later. Can start automatically when
  CarPlay connects.
- "Wrong lyrics?" lets you pick another version from LRCLIB; the choice is remembered.
- Lyrics for the next songs in your queue are prefetched, so they appear instantly even
  with patchy signal. Everything you've seen is cached for offline use.
- Optional: tap a line to jump there (needs Spotify Premium and an extra permission).
- A built-in demo song lets you try everything without a Spotify account.

Setup steps are in **[SETUP.md](SETUP.md)**. Privacy: [PRIVACY.md](PRIVACY.md).
Terms: [TERMS.md](TERMS.md).

## Where lyrics show up in a car, honestly

Apple's CarPlay Developer Guide says audio apps must **"Never show song lyrics on the
CarPlay screen"**, and no other CarPlay category fits a lyrics app. So Apple won't grant
this app a CarPlay entitlement, and the full-screen CarPlay app (a list of lyric lines)
only runs in the Xcode Simulator.

What does work in a real car is a **Live Activity**: since iOS 26, Live Activities appear
on the CarPlay Dashboard without any CarPlay entitlement. Drive mode keeps the app
running in the background (with a silent audio session that mixes with Spotify) so it
can keep the Live Activity's line current. That background trick is fine for a copy you
install yourself from Xcode, but would not pass App Store review. This project is for
personal use, not for distribution.

## How it works

```
Spotify Web API ──(poll 1.25–5 s)──▶ NowPlayingEngine ◀── LRCLIB (/api/get, /api/search)
  /me/player/currently-playing        │ PlaybackClock interpolates between polls
  /me/player/queue (prefetch)         │ (10 ticks/s), per-song + global offsets
                                      ▼
                       NowPlayingSnapshot (track, lyrics, current line)
                 │                     │                         │
          iPhone (SwiftUI)    Live Activity (Drive mode)   CarPlay list (Simulator)
```

| Part | Where |
| --- | --- |
| LRC parsing, timeline, playback clock, sync engine, LRCLIB matching, Spotify clients, PKCE, cache, display rows, demo song | `Packages/LyricsCore` (pure Swift, 116 tests, runs on macOS and Linux) |
| Spotify sign-in and token refresh | `App/Sources/Spotify` |
| Timers and network calls around the engine | `App/Sources/Playback/NowPlayingModel.swift` |
| Drive mode (Live Activity + background keep-alive) | `App/Sources/DriveMode`, `Widget/`, `Shared/` |
| iPhone UI | `App/Sources/UI` |
| CarPlay app screen (Simulator only) | `App/Sources/CarPlay` |
| App unit tests and UI tests (demo mode) | `Tests/` |

### Design notes

- **Spotify Web API, not the iOS SDK.** It sees playback on every device, needs no binary
  SDK and no Spotify app on the phone. The position is polled and interpolated locally;
  disagreements under 0.35 s are ignored so the highlight doesn't flicker. After a
  change (new song, pause, seek) it polls every 1.25 s for a few seconds, and it polls
  right when a song should end to catch the next one quickly.
- **Errors.** A dead zone keeps the lyrics running on the local clock with exponential
  backoff (2 → 30 s). A 403 (account not on the Spotify app's allowlist) says so. 429s
  honour `Retry-After`. A revoked token signs you out cleanly.
- **Lyric matching.** Exact signature match (title, artist, album, duration) first, then
  the title without "- Remastered 2011"/"(feat. …)", then a ranked search. Matches more
  than 3 s off the Spotify duration are rejected as another cut of the song.
- **CarPlay list screen.** Rows are updated in place (no list flicker), aren't tappable,
  and messages never ask the driver to pick up their phone.

## Accessibility

VoiceOver labels throughout (the current line is announced as selected, instrumental
breaks as "Instrumental break"), all lyric colours above 4.5:1 contrast with brighter
values under Increase Contrast, Reduce Motion respected, controls that re-flow at the
largest Dynamic Type sizes, and every gesture also available as a button or
accessibility action.

## Credits

- Lyrics: [LRCLIB](https://lrclib.net), a community database. Lyrics belong to their
  copyright owners.
- Song data and artwork: Spotify. Not affiliated with or endorsed by Spotify or Apple.
- The app icon was drawn for this project (generated in code); symbols are Apple's SF Symbols.
