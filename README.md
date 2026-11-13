<div align="center">

<img src="Swiftbus/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Swiftbus icon">

# Swiftbus

**A fast, native Azure Service Bus manager for macOS.**

Browse queues, topics and subscriptions, dig into dead-letters, fix broken messages and send them
back on their way, without opening the Azure portal.

[![Latest release](https://img.shields.io/github/v/release/lmrisdal/Swiftbus?include_prereleases&label=download)](https://github.com/lmrisdal/Swiftbus/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![CI](https://github.com/lmrisdal/Swiftbus/actions/workflows/ci.yml/badge.svg)](https://github.com/lmrisdal/Swiftbus/actions/workflows/ci.yml)

[Download](https://github.com/lmrisdal/Swiftbus/releases/latest) ·
[Features](#features) ·
[Getting started](#getting-started) ·
[Building from source](#building-from-source)

</div>

<!-- Add a screenshot here, e.g.:
<p align="center"><img src="docs/screenshot.png" width="900" alt="Swiftbus showing a dead-letter queue grouped by reason"></p>
-->

## Features

### 🔭 See everything at a glance

- Every queue, topic and subscription in your namespace with **active and dead-letter counts**.
- Filter down to only the entities that have dead-letters, or search with **⌘F**.
- Pick the layout you like: a single sidebar tree, or a sidebar, a subscription table and the messages.

### 📨 Browse messages

- Switch between **active**, **dead-letter** and **transfer dead-letter** messages (**⌘1**, **⌘2**, **⌘3**).
- Inspect the reason, error description, enqueued time, properties and body, with
  **JSON and XML syntax highlighting**.
- **Group dead-letters by reason** (**⌥⌘G**) to see at once which failure is behind most of them.

### 🛠 Fix and replay

- **Resend** selected dead-letters to their topic and remove them from the dead-letter queue (**⌥⌘R**).
  The original is only removed after the copy has been sent.
- **Repair and resubmit**: edit the body, system properties and typed application properties of a
  message, then send the fixed copy, optionally removing the original.
- **Delete** messages you don't need (**⌘⌫**), and retry any that failed to resend with one click.
- **Save messages as JSON** for a bug report or a closer look.

### ⚙️ Manage your namespace

Right-click a queue or topic to:

- enable or disable it, refresh it or copy its URL,
- create a subscription or send test messages,
- purge messages or dead-letters, or delete the entity.

Anything destructive asks first.

### 🔐 Safe by design

- Connection strings live in your **macOS Keychain**, never in plain text.
- Runs fully **sandboxed**; credentials are passed to the messaging helper over a pipe, never on the command line.
- An **activity log** (**⇧⌘B**) records every action and error, so you always know what happened.
- Light, dark or system appearance.

## Installation

1. Download the latest `.dmg` from [Releases](https://github.com/lmrisdal/Swiftbus/releases/latest).
2. Open it and drag **Swiftbus** to **Applications**.

**Requirements**

- macOS 14 Sonoma or later (Apple silicon and Intel)
- A Service Bus connection string with **Manage**, **Send** and **Listen** rights.
  Manage is needed to list topics and subscriptions; Send and Listen are needed to read, resend and
  delete messages.

## Getting started

1. Open Swiftbus and choose **Add connection**.
2. Paste your connection string, for example
   `Endpoint=sb://my-namespace.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...`
3. Pick a queue, or expand a topic and pick a subscription, to see its messages.

Manage saved connections, appearance and layout any time in **Settings** (**⌘,**).

## Keyboard shortcuts

| Shortcut                 | Action                                               |
| ------------------------ | ---------------------------------------------------- |
| **⌘R**                   | Refresh                                              |
| **⌘F**                   | Find topics                                          |
| **⌘1** / **⌘2** / **⌘3** | Active / dead-letter / transfer dead-letter messages |
| **⌥⌘G**                  | Group dead-letters by reason                         |
| **⌥⌘R**                  | Resend selected messages                             |
| **⌘⌫**                   | Delete selected messages                             |
| **⌘B**                   | Toggle sidebar                                       |
| **⇧⌘B**                  | Toggle activity log                                  |
| **⌘,**                   | Settings                                             |

## Building from source

You need Xcode and the [.NET 10 SDK](https://dot.net). Open `Swiftbus.xcodeproj` in Xcode, choose
your team under **Signing & Capabilities**, and run.

<details>
<summary>How it's put together</summary>

Swiftbus is a SwiftUI app. Entity listing and management use the Service Bus REST API directly from
Swift (`Packages/ServiceBusKit`). Reading and sending messages needs AMQP, so the app bundles a small
Native-AOT .NET helper (`Helper/SwiftbusHelper`) that it talks to over stdin/stdout.

A build phase publishes the helper, puts it in `Contents/Helpers` and signs it with the entitlements
in `Helper/helper.entitlements` so it runs inside the app sandbox. Debug builds contain the helper for
your Mac's architecture; Release builds contain a universal one.

- Tests: `swift test` in `Packages/ServiceBusKit`
- Regenerate the app icon: `swift scripts/make-icon.swift`

See [AGENTS.md](AGENTS.md) for the full architecture and contribution conventions.

</details>
