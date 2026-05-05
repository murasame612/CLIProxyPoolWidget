# Release Checklist

## Build

- Build the Release configuration.
- Confirm the app opens from the Release bundle.
- Confirm `CLIProxyPoolWidgetExtension.appex` is embedded under `Contents/PlugIns`.
- Confirm small, medium, and large widgets render after re-adding them to the desktop.

## Functional Checks

- Save settings and confirm the app reports successful widget sync.
- Click `Test Fetch` and confirm pool summary loads.
- Verify `5h` and `Week` quota totals are consistent between the app and widget.
- Verify restore timing appears for both windows when reset data is available.
- Verify the health timeline shows green/yellow/red buckets based on recent requests.
- Verify sorting by `5h`, `Week`, and `Name`.

## Debug Checks

- If widget data is blank, inspect App Group signing and entitlements.
- If old UI persists, restart `chronod` and re-add the widget.
- If quota appears too pessimistic, inspect whether an account is week-killed.
- If many accounts fail at once, lower concurrency or inspect the management endpoint logs.

## Publish

- Create the DMG under `dist/`.
- Attach `dist/CLIProxyPoolWidget-0.2.0.dmg` to the release.
- Include `docs/RELEASE_NOTES.md` content in the release description.
- Add the required screenshots from `docs/SCREENSHOTS.md`.

