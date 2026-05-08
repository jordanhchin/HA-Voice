# TestFlight Submission Notes

## Beta App Description
HA Voice sends text-to-speech announcements to Home Assistant media players from iPhone and iPad. Testers can connect to a Home Assistant server, pick a speaker, send one-off messages, run repeats, start countdown announcements, and choose Home Assistant Cloud voice presets.

## What To Test
- First-run setup with a Home Assistant server URL and long-lived access token.
- QR token scanning and manual token entry.
- Local network permission prompt when connecting to a `.local` or LAN Home Assistant address.
- Speaker refresh, search, and selection.
- One-off sends, resend, and retry after failure.
- Repeat by count, repeat for duration, repeat until stopped, and countdown mode.
- Settings persistence for server, selected speaker, sender name, voice, and message history.
- Background warning behavior for longer repeat or countdown sessions.

## Beta Review Notes
This app requires a reachable Home Assistant server with a valid long-lived access token and Home Assistant TTS service support. It sends requests only to the Home Assistant server configured by the tester.

If Apple beta review needs hands-on access, provide a temporary Home Assistant test endpoint and long-lived token in App Store Connect review notes. Do not include production Home Assistant credentials in the app binary or repository.

## Privacy And Compliance
- Tracking: No.
- Third-party analytics or advertising SDKs: None.
- Data collection for App Store privacy labels: None expected for this app.
- Local storage: Home Assistant token in Keychain; non-secret preferences and recent message history in UserDefaults.
- Network access: Requests go to the tester-configured Home Assistant server.
- Encryption/export compliance: Uses standard Apple networking and system cryptography only; no custom or non-exempt encryption is implemented.
