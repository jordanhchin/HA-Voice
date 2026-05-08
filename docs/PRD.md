# PRD: HA Voice iOS/iPadOS App

## Summary
Build a native iPhone/iPad app for sending text-to-speech announcements to Home Assistant `media_player` entities through the Home Assistant REST API and `tts.cloud_say`.

The v1 experience should feel like a focused messaging app: choose a target speaker, type a message, optionally configure voice/repeat/countdown behavior, send it, and see delivery history/status.

Primary user goals:
- Connect to one Home Assistant server using a manual server URL and long-lived access token.
- Load available `media_player.*` entities from Home Assistant.
- Quickly switch the active media player before sending.
- Send one-off spoken messages through `tts.cloud_say`.
- Repeat messages by count, duration, or until manually stopped.
- Run countdown announcements such as “You have 10 minutes until it’s time to go.”
- Choose language/voice options for Home Assistant Cloud TTS.
- Remember server, selected target, selected voice, and sent-message history.

## Key Product Requirements
- **Setup**
  - First launch asks for Home Assistant server URL and long-lived access token.
  - Include a “Test Connection” action that validates the token and server reachability.
  - Store the access token securely in Keychain.
  - Store non-secret preferences such as server URL, selected media player, selected voice, and history locally.

- **Device Selection**
  - Fetch Home Assistant states and filter to `entity_id` values beginning with `media_player.`.
  - Display friendly names when available, with entity IDs as secondary labels.
  - Allow quick target switching from the main composer.
  - Include refresh, search, and offline/error states.

- **Message Interface**
  - Main screen resembles a text-message thread of messages sent by this app.
  - Composer includes message text, active target, selected voice/language, and send button.
  - Each sent item shows message text, target, timestamp, voice/language, delivery result, and repeat/countdown metadata if applicable.
  - Failed sends remain visible with a clear retry action.

- **TTS Sending**
  - Use Home Assistant REST service calls:
    - `POST /api/services/tts/cloud_say`
    - Payload includes `entity_id`, `message`, optional `language`, optional `cache`, and optional `options`.
  - Default `cache` to `false` for ad-hoc messages unless changed later.
  - Voice changes are sent through `options.voice` where supported by Home Assistant Cloud TTS.
  - Language is stored separately from voice and sent as `language`.

- **Repeat Messages**
  - User can choose exactly one repeat mode:
    - Send once.
    - Repeat N times.
    - Repeat for a duration.
    - Repeat indefinitely until stopped.
  - User can set repeat interval in seconds/minutes.
  - Active repeats show an obvious running state and Stop control.
  - Because the user selected best-effort background behavior, repeats should continue while the app is active and request short background execution when the app leaves the foreground, but the PRD must state that iOS may pause longer-running repeats.
  - If iOS pauses a repeat, the app should surface that status when reopened.

- **Countdown Messages**
  - Countdown mode lets the user enter total time, interval, target, voice, and message template.
  - Default template: `You have {minutes} minutes until it's time to go.`
  - At each interval, the app computes remaining time and sends a message.
  - Include final-message behavior, defaulting to: `It's time to go.`
  - Countdown sessions appear as active items with remaining time and Stop control.

- **Voice Controls**
  - v1 should provide editable built-in voice presets rather than depending on dynamic voice discovery.
  - Each preset has display name, language, and `options.voice` value.
  - Include “Default Home Assistant voice” as an option that omits `options.voice`.
  - Let users add/edit/delete custom voice presets.
  - Note in the PRD that Home Assistant Cloud language/voice availability can change.

## Technical Interfaces
- Home Assistant API:
  - Authenticate every request with `Authorization: Bearer <token>`.
  - Use JSON requests with `Content-Type: application/json`.
  - Fetch entities from `GET /api/states`.
  - Send TTS through `POST /api/services/tts/cloud_say`.
- Local app model:
  - `ServerProfile`: server URL, display name, connection status.
  - `MediaPlayerTarget`: entity ID, friendly name, state, attributes.
  - `VoicePreset`: display name, language, voice option value, whether it is custom.
  - `MessageRecord`: text, target, voice preset, timestamp, send status, error if any.
  - `RepeatSession`: message template, target, voice, interval, repeat mode, current status.
  - `CountdownSession`: duration, interval, remaining time, template, final message, current status.

## UX Structure
- **Main screen**
  - Message history.
  - Composer.
  - Target picker.
  - Voice picker.
  - Repeat/countdown controls.
- **Devices screen or sheet**
  - Searchable media player list.
  - Refresh action.
  - Current selection indicator.
- **Voice presets screen**
  - Built-in presets.
  - Custom preset editor.
  - Default voice option.
- **Settings**
  - Home Assistant server URL.
  - Token replacement.
  - Test connection.
  - Clear message history.
  - Background behavior explanation for repeats.

## Test Plan
- Unit tests:
  - URL normalization and token validation rules.
  - Filtering `media_player.*` entities from Home Assistant state responses.
  - `tts.cloud_say` payload construction with and without voice/language.
  - Repeat scheduling for count, duration, and indefinite modes.
  - Countdown message generation at expected intervals.

- Integration-style tests with mocked Home Assistant:
  - Successful connection test.
  - Failed auth.
  - Empty media player list.
  - Successful TTS send.
  - Service failure response.
  - Retry failed message.

- UI tests:
  - First-run setup.
  - Select media player.
  - Send one message.
  - Start and stop repeat.
  - Start and stop countdown.
  - Change voice preset.
  - Reopen app and confirm selected server, target, voice, and history persist.

## Assumptions And Defaults
- v1 uses manual Home Assistant URL plus long-lived access token.
- v1 targets only `media_player` entities.
- v1 sends through `tts.cloud_say`, even though Home Assistant documents `tts.speak` as the newer TTS action pattern.
- Repeats are best-effort in background, not guaranteed indefinite background automation.
- Reliable indefinite repeats via Home Assistant-side scripts/automations are out of v1 scope.
- Voice discovery is not required for v1; editable presets are sufficient.
- References used for API/service assumptions: [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/), [Home Assistant TTS docs](https://www.home-assistant.io/integrations/tts), and [Nabu Casa Cloud TTS](https://support.nabucasa.com/hc/en-us/articles/25619386304541-Text-to-speech-TTS).
