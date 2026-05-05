# Release Notes

## v0.2.0 - 2026-05-05

### New Features

- Added macOS WidgetKit support for small, medium, and large desktop widgets.
- Added a compact medium widget layout with two quota rings: `5h` on the left, `Week` on the right, and restore timing in the center.
- Added widget restore forecasts for both quota windows, including the next restored percentage and time until restore.
- Added large-widget health overview with recent success/failure history instead of a long account list.
- Added app-level health timeline using recent request buckets from CLIProxyAPI auth files.
- Added account sorting in the main app by `5h`, `Week`, or `Name`.
- Added account display limit handling in the app view, separate from the total account pool calculation.
- Added merged pool-level recent request health for the whole visible pool.

### Quota And Health Logic

- Fetches usage in small concurrent batches to reduce pressure on the management endpoint.
- Retries ChatGPT usage fetch once before marking an account fetch as failed.
- Treats JSON responses without direct quota fields as usable fallback snapshots, so auth-file availability can still drive account status.
- Tightened rate-limit/quota parsing so a generic "limit" word is not enough to mark an account as fully exhausted.
- Includes weekly reset events when estimating the next restored `5h` capacity for week-killed accounts.
- Shows App Group sync failure in the app when widget settings cannot be written.

### UI Changes

- Removed oversized headline quota text from the small widget.
- Reworked the medium widget into balanced rings and a restore card.
- Enlarged ring detail quota text for readability.
- Reduced widget header typography so quota data remains the visual focus.
- Replaced the large-widget account list with an overall health card.

### Debug Notes

- Widget data depends on App Group entitlement support. Personal Team provisioning may not reliably grant App Groups for a WidgetKit extension.
- If the widget shows old UI after installing a new build, remove and re-add the widget or restart `chronod`.
- If the widget has no data while the app does, check App Group signing first.

### Known Limitations

- The Management key is still stored in user defaults, not Keychain.
- Release builds are locally signed for development unless a paid Apple Developer account and notarization workflow are added.
- Desktop widget settings sync may fail under free Personal Team signing.

