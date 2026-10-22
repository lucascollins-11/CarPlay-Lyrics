# CarPlay Lyrics

An iPhone app with a CarPlay screen that shows time-synced lyrics for whatever you
are playing on Spotify.

- Sign in once with your Spotify account (works with any device you play on: the phone,
  the car, a speaker).
- The app follows the song and highlights the line being sung, on the phone and in CarPlay.
- Lyrics come from [LRCLIB](https://lrclib.net), a free, open database of synced lyrics,
  and are cached on the phone.
- Timing can be nudged ±0.25 s from the phone or the CarPlay top bar.

Setup steps are in **[SETUP.md](SETUP.md)**.

## How it works

```
Spotify Web API ──(poll every 3 s)──▶ NowPlayingModel ◀── LRCLIB (/api/get, /api/search)
  /me/player/currently-playing         │  PlaybackClock interpolates the position
                                       │  between polls (10 ticks/s)
                                       ▼
                         Snapshot (track, lyrics, current line)
                           │                           │
                    SwiftUI iPhone screen      CarPlay CPListTemplate
```

| Part | Where |
| --- | --- |
| LRC parsing, line lookup, playback clock, LRCLIB matching, Spotify JSON | `Packages/LyricsCore` (pure Swift, unit tested) |
| Spotify sign-in (PKCE, tokens in Keychain) | `App/Sources/Spotify/SpotifyAuth.swift` |
| Polling Spotify, loading lyrics, current line | `App/Sources/Playback/NowPlayingModel.swift` |
| Lyrics cache | `App/Sources/Playback/LyricsRepository.swift` |
| iPhone UI | `App/Sources/UI` |
| CarPlay UI | `App/Sources/CarPlay/CarPlaySceneDelegate.swift` |

### Design notes

- **Why the Web API and not the Spotify iOS SDK?** The Web API sees playback on every
  device (including Spotify running natively in some cars), needs no binary SDK, and
  needs no Spotify app on the phone. The cost is polling: the position is fetched every
  3 s and interpolated locally, with small disagreements (< 0.35 s) ignored so the
  highlight doesn't flicker. When a song should have ended, the app polls right away
  to catch the next track.
- **CarPlay screen.** CarPlay apps can't draw custom views, only Apple's templates. The
  app uses a list template: the previous line, the current line (marked with CarPlay's
  playing indicator), and the next lines. Long lines wrap onto the row's second line.
- **Lyric matching.** Exact match by title, artist, album and duration first; then the
  title without suffixes like "- Remastered 2011" or "(feat. …)"; then a search ranked by
  title, artist, duration (within 5 s) and synced over plain lyrics.

## Limits worth knowing

- A real car needs Apple's CarPlay entitlement, which Apple may not grant for a lyrics
  app (see SETUP.md, step 5). The Simulator works without it.
- Spotify apps in Development mode only work for accounts you add in the Spotify dashboard.
  Publishing to the App Store would also need Spotify's extended quota approval and a
  look at lyric licensing, since LRCLIB lyrics are community submitted.
