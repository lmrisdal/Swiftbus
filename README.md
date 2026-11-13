<div align="center">

<img src="Swiftbus/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Swiftbus icon">

# Swiftbus

**A fast, native Azure Service Bus manager for macOS.**

Browse your queues, topics and subscriptions, peek at messages, send new ones and keep your
namespace tidy, all from a proper Mac app instead of the Azure portal.

[![Latest release](https://img.shields.io/github/v/release/lmrisdal/Swiftbus?include_prereleases&label=download)](https://github.com/lmrisdal/Swiftbus/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![CI](https://github.com/lmrisdal/Swiftbus/actions/workflows/ci.yml/badge.svg)](https://github.com/lmrisdal/Swiftbus/actions/workflows/ci.yml)

[Download](https://github.com/lmrisdal/Swiftbus/releases/latest/download/Swiftbus.dmg) ·
[Features](#features) ·
[Getting started](#getting-started) ·
[Building from source](#building-from-source)

</div>

> **Early beta software:** Swiftbus is still under active development; expect bugs and changes.

## Features

### 🔭 Your namespace at a glance

- Every queue, topic and subscription with its **message counts**, in a sidebar tree or a
  sidebar-plus-table layout, whichever you prefer.
- Search with **⌘F**, refresh with **⌘R**, and switch between connections in a click.

### 📨 Browse messages

- Peek at **active**, **dead-letter** and **transfer dead-letter** messages (**⌘1**, **⌘2**, **⌘3**).
- Inspect body, system properties and typed application properties, with **JSON and XML syntax
  highlighting**.
- **Save messages as JSON** to share or look at later.

### ✉️ Send and resubmit

- **Send messages** to any queue or topic: body, content type, subject, IDs and typed application
  properties, with JSON formatting built in. Send one or many at once.
- **Edit and resubmit** an existing message, or resend selected messages in bulk with progress you can
  follow.
- Dead-lettered messages can be grouped by reason (**⌥⌘G**) when you need to work through them.

### ⚙️ Manage entities

Right-click a queue or topic to:

- enable or disable it, refresh it or copy its URL,
- create a subscription,
- purge its messages, or delete it.

## Installation

1. [Download **Swiftbus.dmg**](https://github.com/lmrisdal/Swiftbus/releases/latest/download/Swiftbus.dmg) (latest release).
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
