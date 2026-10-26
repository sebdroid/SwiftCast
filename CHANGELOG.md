# Changelog

## Unreleased

### Breaking

- `CastError.loadFailed`, `.loadCancelled`, `.invalidPlayerState` and `.invalidRequest` now carry a
  `MediaErrorInfo` (`type`, `reason`, `detailedErrorCode`, `itemId`, `customData`) instead of loose
  reason strings. New cases `mediaError(MediaErrorInfo)`, `invalidPayload(String)` and
  `messageTooLarge(Int)`. Exhaustive switches over `CastError` need the new arms; `mediaErrorInfo`
  returns the details for any media error without a switch.
- `CastVolume.ControlType` is an open enum with `.unknown(String)`, and `ControlType(rawValue:)` is
  no longer failable. Use `CastVolume.canSetVolume` instead of comparing against `.fixed` by hand.
- `CastDevice.Capabilities.rawValue` is `UInt64`. Discovered device ids are normalised (leading
  `uuid:` removed, dashes removed, lowercased), so persisted ids for some devices change once.
- `ReceiverStatus` fails to decode when `applications` is not an array or an entry is malformed or
  has an empty `sessionId` or `transportId`; the status listeners ignore such a status, request
  paths throw.
- After `MediaController.stop()` (or an `INVALID_MEDIA_SESSION_ID` reply) session commands throw
  `CastError.noMediaSession` locally until new media is loaded; `hasActiveSession` reports the state.
- A media reply that is not `MEDIA_STATUS` throws `unexpectedResponse` instead of returning the
  cached status, and status updates merge field by field, so a field the receiver leaves out keeps
  its previous value.
- Outbound messages over 65 536 bytes throw `messageTooLarge` instead of being sent.

### Fixed

- A JSON integer outside `Int` (for example `requestId` 2^63) no longer crashes the host app;
  `requestId` is read as a 32-bit integer like Chrome does.
- Error replies on the media namespace (`ERROR`, `INVALID_PLAYER_STATE`, `LOAD_FAILED`,
  `LOAD_CANCELLED`, `INVALID_REQUEST`) are reported as errors with their details.
- `MediaStatus` broadcasts no longer blank the queue or other fields the receiver omitted.
- TV show metadata uses the `originalAirdate` wire key; the `originalAirDate` spelling still decodes.
- Receiver status decoding survives unexpected `controlType` strings and bad optional fields.
- Inbound frames are decoded without shifting the buffer per frame, messages decoded before a bad
  frame are still delivered, and messages Chrome's `IsCastMessageValid` rejects are rejected.
- `ca` capability flags parse as unsigned, so a negative value no longer sets every flag; the
  multichannel, dynamic group, volume and Cast Connect bits are modelled.
- Device-supplied text in error descriptions and `castctl` output is stripped of control and
  bidi characters.

### Changed

- `CastDeviceBrowser` keeps a device listed for 30 seconds after it disappears from Bonjour,
  keeps a device's endpoint when another result advertises the same id, and marks the previous
  roster unseen when browsing restarts.
- `CastDevice` exposes `deviceVersion`, `status`, `runningApplicationID`, `iconPath` and `Kind`.
- Inbound frame cap is 131 068 bytes (a 128 KiB frame including the length prefix).
- CI pins `actions/checkout` by commit, builds visionOS and runs on tags; the README documents the
  macOS local network requirements.

## 1.0.1

- `CastClient.disconnect()` no longer sends `CLOSE` to application connections. Web receivers
  treat an explicit `CLOSE` from their last sender as a shutdown request, so disconnecting used
  to stop playback on the TV.
- Fixed a race where `MediaController` could re-apply a stale reply to its own `GET_STATUS`
  after a newer `LOAD`, clearing the media session.
- Fixed a race where `CastSession` could attach two media controllers to one application when a
  load overlapped a receiver status update.
- `castctl play` now follows status for a few seconds and prints idle reasons.

## 1.0.0

- Initial release: Cast V2 protocol client, Bonjour discovery, receiver and media controllers,
  queue and track support, custom namespaces, observable `CastSession` with automatic
  reconnection, SwiftUI `CastButton`/`CastDevicePicker`, and the `castctl` CLI.
