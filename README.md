# Swiftbus

An Azure Service Bus manager for macOS.

> **Status:** early development. The app builds, but the features below are not finished yet.

## Features

- Connect with a Service Bus connection string. Saved connections are kept in your Keychain.
- See every topic and subscription with its active and dead-letter counts, filtered to only the
  ones with dead-letters if you like.
- Browse a subscription's dead-letter queue: reason, error description, enqueued time, properties
  and message body.
- Resend selected messages to the topic and remove them from the dead-letter queue, or delete them.

## Requirements

- macOS 14 or later
- A connection string with **Manage**, **Send** and **Listen** rights. Manage is needed to list
  topics and subscriptions.

## Getting started

1. Open Swiftbus and choose **Add connection**.
2. Paste your connection string, for example
   `Endpoint=sb://my-namespace.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...`
3. Pick a topic in the sidebar, then a subscription to see its dead-lettered messages.

## Good to know

Service Bus can only send to a topic, not to a single subscription. A resent message goes to every
subscription whose filter matches it, not just the one it came from.

## Building from source

Open `Swiftbus.xcodeproj` in Xcode, choose your team under **Signing & Capabilities**, and run.
