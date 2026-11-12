# Swiftbus

An Azure Service Bus manager for macOS.

## Features

- Connect with a Service Bus connection string. Saved connections are kept in your Keychain.
- See every topic and subscription with its active and dead-letter counts, filtered to only the
  ones with dead-letters if you like.
- Browse a subscription's dead-letter queue: reason, error description, enqueued time, properties
  and message body.
- Resend selected messages to the topic and remove them from the dead-letter queue, or delete them.
- Right-click a queue or topic in the sidebar to disable/enable, delete, refresh, copy its URL, create a
  subscription (topics), send test messages, or purge messages / dead-letters. Delete and purge ask first and
  can't be undone. Renaming isn't offered: Service Bus has no rename operation.

Also included: an activity log (⌥⌘L) and a retry button for
messages that failed to resend.

## Requirements

- macOS 14 or later
- A connection string with **Manage**, **Send** and **Listen** rights. Manage is needed to list
  topics and subscriptions.

## Getting started

1. Open Swiftbus and choose **Add connection**.
2. Paste your connection string, for example
   `Endpoint=sb://my-namespace.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...`
3. Pick a topic in the sidebar, then a subscription to see its dead-lettered messages.

## Building from source

You need Xcode and the [.NET 10 SDK](https://dot.net). Open `Swiftbus.xcodeproj` in Xcode, choose
your team under **Signing & Capabilities**, and run. A build phase publishes the messaging helper
(`Helper/SwiftbusHelper`, Native AOT), puts it in `Contents/Helpers` and signs it with the entitlements
in `Helper/helper.entitlements` so it runs inside the app sandbox. Debug builds contain the helper for
your Mac's architecture; Release builds contain a universal one.

Tests: `swift test` in `Packages/ServiceBusKit`. To regenerate the app icon: `swift scripts/make-icon.swift`.

## Sharing the app (signing and notarization)

1. Product → Archive, then **Distribute App → Direct Distribution** with a Developer ID Application
   certificate. Xcode signs the app and the helper (hardened runtime is on) and offers to notarize.
2. Or from the command line, after exporting the archive to `Swiftbus.app`:

   ```bash
   ditto -c -k --keepParent Swiftbus.app Swiftbus.zip
   xcrun notarytool submit Swiftbus.zip --keychain-profile "<profile>" --wait
   xcrun stapler staple Swiftbus.app
   ```

The helper must keep its `app-sandbox` and `inherit` entitlements; without them macOS refuses to start
it from inside the sandboxed app.
