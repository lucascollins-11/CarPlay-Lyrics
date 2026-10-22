# Privacy Policy

Effective date: 22 October 2026

Lyrics ("CarPlay Lyrics", "the app") shows time-synced lyrics for the song playing on your Spotify account. This policy explains what the app does with your data. In short: it has no server, no accounts of its own, no analytics, no ads and no tracking.

## What the app reads from Spotify

- When you choose "Continue with Spotify", you sign in on Spotify's own page. The app asks only for read access to what is currently playing (`user-read-currently-playing` and `user-read-playback-state`). It can't see your playlists, library, email address or payment details.
- If you turn on "Tap a line to jump there" in Settings, the app also asks for permission to control playback (`user-modify-playback-state`). It uses it only to jump to the line you tap.
- Sign-in uses Spotify's PKCE flow. The resulting tokens are stored in the iOS Keychain on this iPhone only (not synced to iCloud or restored to other devices), and are only ever sent to Spotify.
- While the app is open, or Drive mode is on, it asks Spotify every few seconds what is playing: the song's title, artists, album, length, Spotify track ID, playback position and artwork address.
- When you open Settings, the app reads your Spotify display name (`GET /v1/me`) to show "Signed in as …". It is kept only in memory while Settings is open; it isn't saved, logged or sent anywhere.

## What the app sends to others

- **LRCLIB** (lrclib.net), a free, community-run lyrics database, receives the song title, artist, album and length so it can return matching lyrics. No account details, track IDs, device identifiers or location are sent. LRCLIB's own terms and privacy practices apply to those requests.
- **Spotify's image servers** (i.scdn.co) deliver album artwork.
- Nothing is sent anywhere else. There is no server of our own, and no data is sold or shared.

## What stays on your iPhone

- Lyrics you've seen, and the versions you picked with "Wrong lyrics?", saved in the app's own storage on this iPhone so songs load instantly and offline. They are excluded from iCloud and computer backups. "Delete my data" removes them.
- Your settings, such as timing adjustments per song and per audio output (car, Bluetooth, AirPlay, wired, speaker), how early Drive mode sends lines, text size and Drive mode, saved in the app's preferences.
- Notifications: when you first start Drive mode, the app asks permission to send notifications. It uses it only for one local reminder the day before a sideloaded build expires. The reminder is scheduled on this iPhone; nothing is sent off the device.
- While Drive mode is on, a Live Activity with the current lyric line, which iOS shows on the Lock Screen, in the Dynamic Island and on the CarPlay Dashboard.

## Cookies and tracking

The app itself uses no cookies, advertising identifiers or tracking of any kind, and doesn't ask for App Tracking Transparency permission. The Spotify sign-in page runs in Apple's secure sign-in sheet, and any cookies there are Spotify's.

## Deleting your data

- **Settings > Delete my data** signs you out, deletes the tokens, the saved lyrics and all settings, and ends Drive mode.
- To also remove the app's access on Spotify's side, go to [spotify.com/account/apps](https://www.spotify.com/account/apps/) and remove it.
- Deleting the app removes everything it stored on the iPhone.

## Children

The app is not aimed at children under 13 and doesn't knowingly collect any data from them. Spotify's own age requirements apply to the Spotify account you sign in with.

## Third parties

| Service | What it receives | Why |
| --- | --- | --- |
| accounts.spotify.com | Sign-in and token refresh requests | Signing in to Spotify |
| api.spotify.com | Requests with your access token | Reading what's playing; jumping to a line if you turned that on |
| i.scdn.co | Artwork requests | Album art |
| lrclib.net | Title, artist, album, length | Finding lyrics |

The app contains no third-party SDKs.

## Changes and contact

If this policy changes, the effective date above changes too, and the new version ships with the app. Contact: open an issue at https://github.com/lucascollins-11/CarPlay-Lyrics/issues, or use the support email in the app's About screen if one is set.
