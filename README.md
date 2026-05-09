# HA Voice

HA Voice is a native iPhone and iPad app for sending spoken announcements to Home Assistant media players. It connects directly to a user-provided Home Assistant server, loads available `media_player.*` entities, and sends text-to-speech messages through the Home Assistant REST API.

The app is intended for quick household announcements: pick a speaker, type a message, choose a voice, and send. It also supports repeated announcements and countdown-style reminders such as "You have 10 minutes until it's time to go."

## Features

- Connect to a Home Assistant instance with a server URL and long-lived access token.
- Store the Home Assistant token securely in the iOS Keychain.
- Scan a token QR code or enter a token manually.
- Fetch and search Home Assistant `media_player.*` entities.
- Send one-off messages through `tts.cloud_say`.
- Send a message with an optional sender prefix, such as `Jordan says: Time to leave`.
- Retry failed sends and resend previous messages from local history.
- Repeat messages by count, by duration, or until manually stopped.
- Run countdown announcements with a configurable interval, template, and final message.
- Choose built-in Home Assistant Cloud TTS voice presets or add custom voice presets.
- Persist non-secret preferences and recent message history locally.
- Surface background-delivery warnings when repeat or countdown work may be paused by iOS.

## Requirements

- Xcode with iOS 18 SDK support.
- iPhone or iPad running iOS/iPadOS 18.0 or later.
- A reachable Home Assistant server.
- A Home Assistant long-lived access token.
- At least one Home Assistant `media_player` entity.
- Home Assistant TTS support for `tts.cloud_say`.

## Home Assistant Setup

1. Open Home Assistant.
2. Go to your user profile.
3. Create a long-lived access token.
4. Make sure the iPhone or iPad can reach the Home Assistant server URL, for example `http://homeassistant.local:8123`.
5. Confirm that the target speakers appear as `media_player.*` entities in Home Assistant.

HA Voice sends authenticated requests directly to the configured Home Assistant server:

- `GET /api/` to test the connection.
- `GET /api/states` to load media players.
- `POST /api/services/tts/cloud_say` to send announcements.

## Building

Open the project in Xcode:

```sh
open "HA Voice.xcodeproj"
```

Select the `HA Voice` scheme, then build and run on an iOS simulator or device.

For personal builds, update signing as needed in Xcode. The checked-in project currently uses the bundle identifier `WaverlyWorks.net.HA-Voice`; public forks should change the bundle identifier and development team before distributing their own build.

## Testing

The project includes unit tests for the core Home Assistant client and app model behavior, including:

- Server URL normalization.
- Token validation.
- Media-player filtering from Home Assistant state responses.
- `tts.cloud_say` payload construction.
- Built-in voice presets.
- Repeat completion rules.
- Countdown message formatting.
- Sender-name message formatting.
- QR token parsing.

Run tests from Xcode with the `HA Voice` scheme, or from the command line when simulator services are available:

```sh
xcodebuild test -project "HA Voice.xcodeproj" -scheme "HA Voice" -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Privacy

HA Voice does not include analytics, advertising SDKs, or tracking code.

Data handled by the app:

- The Home Assistant access token is stored in the iOS Keychain.
- Server URL, selected speaker, selected voice, sender name, and recent message history are stored locally in `UserDefaults`.
- Network requests are sent only to the Home Assistant server configured in the app.
- No production Home Assistant credentials should be committed to this repository.

## Background Behavior

Repeat and countdown sessions are best-effort while HA Voice is in the background. The app requests short background execution when needed, but iOS may pause longer-running work. For mission-critical or long-running announcements, prefer a Home Assistant-side script or automation.

## Current Scope

HA Voice currently focuses on manual setup and Home Assistant Cloud TTS through `tts.cloud_say`. It does not yet include:

- Home Assistant OAuth onboarding.
- Dynamic voice discovery.
- Home Assistant-side automation creation.
- Guaranteed indefinite background repeats.
- Cloud relay, hosted backend, or account system.

## Repository Layout

```text
HA Voice/                  App source, SwiftUI views, models, networking, storage, and assets
HA VoiceTests/             Unit tests
HA VoiceUITests/           UI test target
Config/                    App configuration files
docs/PRD.md                Product requirements and design notes
docs/TESTFLIGHT.md         TestFlight and beta review notes
```

## Documentation

- [Product requirements](docs/PRD.md)
- [TestFlight notes](docs/TESTFLIGHT.md)

## License

No open-source license has been added yet. Until a license is provided, all rights are reserved by the repository owner.
