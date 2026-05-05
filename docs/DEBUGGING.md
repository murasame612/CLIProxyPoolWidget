# Debugging And Health Checks

This project has two moving parts: the main macOS app and the WidgetKit extension bundled inside the app.

## Local Health Check

Use this sequence before publishing a DMG:

```bash
xcodebuild \
  -scheme CLIProxyPoolWidget \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=3T3V5AFBPB \
  build
```

Then verify the app bundle contains the widget extension:

```bash
test -d .build/DerivedData/Build/Products/Release/CLIProxyPoolWidget.app/Contents/PlugIns/CLIProxyPoolWidgetExtension.appex
```

## Refresh WidgetKit During Development

```bash
killall chronod
swift -module-cache-path .build/SwiftModuleCache -e 'import WidgetKit; WidgetCenter.shared.reloadAllTimelines(); print("reloaded")'
```

If the desktop still shows an old snapshot, remove the widget and add it again.

## App Has Data, Widget Has No Data

The most likely cause is App Group signing.

The app writes widget settings into:

```text
3T3V5AFBPB.com.zipwuu.CLIProxyPoolWidget
```

Both targets must have the same App Group entitlement and must be signed with a provisioning profile that grants that App Group. Free Personal Team provisioning may ignore or reject the entitlement for extensions.

Recommended fixes:

- Use a paid Apple Developer account and create the App Group in Certificates, Identifiers & Profiles.
- Keep the same App Group string in `Shared/PoolModels.swift`, `App/CLIProxyPoolWidget.entitlements`, and `Widget/CLIProxyPoolWidgetExtension.entitlements`.
- Rebuild and reinstall the app after signing changes.

## Useful Inspection Commands

Check the embedded extension:

```bash
ls -la /Applications/CLIProxyPoolWidget.app/Contents/PlugIns/
```

Inspect entitlements:

```bash
codesign -d --entitlements :- /Applications/CLIProxyPoolWidget.app
codesign -d --entitlements :- /Applications/CLIProxyPoolWidget.app/Contents/PlugIns/CLIProxyPoolWidgetExtension.appex
```

Check WidgetKit registration:

```bash
pluginkit -m -v -A -p com.apple.widgetkit-extension | rg "CLIProxy|zipwuu"
```

Watch widget logs:

```bash
log stream --predicate 'subsystem CONTAINS "widget" OR process CONTAINS "chronod"' --style compact
```

## Packaging

The release DMG is generated from the Release app bundle:

```bash
mkdir -p dist
hdiutil create \
  -volname "CLIProxyPoolWidget" \
  -srcfolder .build/DerivedData/Build/Products/Release/CLIProxyPoolWidget.app \
  -ov \
  -format UDZO \
  dist/CLIProxyPoolWidget-0.2.0.dmg
```

