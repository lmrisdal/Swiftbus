# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository. Read this before making
changes. For the user-facing description of the app, see [README.md](README.md).

## What this is

**Swiftbus** is a native macOS (14+) app for managing Azure Service Bus namespaces: list
topics/subscriptions/queues with their active and dead-letter counts, browse active and dead-lettered
messages, group dead-letters by failure reason, and resend or delete them.

It is built from three parts:

| Part | Language | Role |
| --- | --- | --- |
| `Swiftbus/` | Swift 6, SwiftUI | The sandboxed macOS app (UI + view models) |
| `Packages/ServiceBusKit/` | Swift 6, SwiftPM | All non-UI logic: connection strings, SAS tokens, REST management client, helper client, dead-letter analysis/actions |
| `Helper/SwiftbusHelper/` | C# / .NET 10, Native AOT | `swiftbus-helper`, a small child process that speaks AMQP via `Azure.Messaging.ServiceBus` |

Why a .NET helper? Listing entities and counts uses the Service Bus **REST management API** (plain
HTTPS, done in Swift). Peeking, receiving, completing and sending messages needs **AMQP**, for which
there is no good Swift client, so the app shells out to a bundled Native-AOT binary. The UI only sees
the `MessagingClient` protocol, so the helper could later be replaced by a pure-Swift implementation.

## Repository layout

```
.
├── AGENTS.md                      ← this file
├── README.md                      ← user-facing docs, build & notarization steps
├── Swiftbus.xcodeproj             ← app project (schemes: Swiftbus, ServiceBusKit)
├── Swiftbus/                      ← app target (file-system-synchronized group)
│   ├── SwiftbusApp.swift          ← @main, creates AppModel, installs AppCommands
│   ├── AppModel.swift             ← @MainActor @Observable root state: connections, topics,
│   │                                queues, sidebar selection, auto-refresh, MessagingClient
│   ├── ConnectionStore.swift      ← saved connections: names in UserDefaults, secrets in Keychain
│   ├── ConnectionSheet.swift      ← "Add connection" sheet
│   ├── ContentView.swift          ← NavigationSplitView: sidebar + entity list
│   ├── DeadLetterModel.swift      ← view model for one entity's message list, resend/delete runs
│   ├── EntitySheets.swift         ← "Create subscription" and "Send messages" sheets
│   ├── MessagesView.swift         ← message table, detail pane, action progress UI
│   ├── ActivityLog.swift          ← in-memory log of actions/errors
│   ├── ActivityLogView.swift      ← activity log window (⌥⌘L)
│   ├── AppCommands.swift          ← menu commands / keyboard shortcuts
│   └── Assets.xcassets            ← app icon (generated) and accent color
├── Packages/ServiceBusKit/        ← local Swift package, linked into the app
│   ├── Package.swift              ← swift-tools 6.0, macOS 14, no external dependencies
│   ├── Sources/ServiceBusKit/
│   │   ├── ConnectionString.swift     ← parses Endpoint=…;SharedAccessKeyName=…;SharedAccessKey=…
│   │   ├── SASToken.swift             ← SAS token generation + cache
│   │   ├── ManagementClient.swift     ← REST management API (Atom feeds), paging, retries,
│   │   │                                 concurrency limit; `HTTPTransport` protocol for tests
│   │   ├── AtomParser.swift           ← XML Atom feed → entries
│   │   ├── Models.swift               ← Topic, Subscription, Queue, counts
│   │   ├── Messaging.swift            ← `MessagingClient` protocol, DeadLetterMessage, MessageResult
│   │   ├── HelperMessagingClient.swift← actor that runs swiftbus-helper and speaks JSON lines
│   │   ├── DeadLetterAnalysis.swift   ← groups dead-letters by normalized reason + description signatures
│   │   ├── DeadLetterActions.swift    ← batched resend/delete with per-batch progress
│   │   ├── PurgeActions.swift         ← purge a queue, or every subscription of a topic
│   │   ├── ServiceBusError.swift      ← user-readable error cases
│   │   └── ServiceBusKit.swift        ← version constant
│   └── Tests/ServiceBusKitTests/      ← Swift Testing (`@Test`, `#expect`) suites
├── Helper/
│   ├── SwiftbusHelper/
│   │   ├── SwiftbusHelper.csproj  ← net10.0, PublishAot, Azure.Messaging.ServiceBus
│   │   ├── Program.cs             ← stdin/stdout JSON-lines loop, error-code mapping
│   │   ├── Protocol.cs            ← Request/Response DTOs + source-generated JSON context
│   │   └── Operations.cs          ← peek, resend, delete against Service Bus
│   ├── helper.entitlements        ← app-sandbox + inherit (required!)
│   └── scripts/build-helper.sh    ← Xcode build phase: publish, lipo, copy, codesign
└── scripts/make-icon.swift        ← regenerates the AppIcon PNGs
```

## Architecture and data flow

```
SwiftUI views ──► AppModel / DeadLetterModel (@MainActor, @Observable)
                     │                         │
                     ▼                         ▼
             ManagementClient          any MessagingClient
          (REST over HTTPS, SAS)       = HelperMessagingClient (actor)
                     │                         │  JSON lines over stdin/stdout
                     ▼                         ▼
            Service Bus REST API     Contents/Helpers/swiftbus-helper (.NET AOT)
                                               │  AMQP
                                               ▼
                                         Service Bus
```

- **Management (Swift):** `ManagementClient` lists topics, subscriptions, queues and counts, and also
  deletes queues/topics, creates subscriptions and enables/disables entities (GET the description, flip
  `<Status>`, PUT it back with `If-Match: *`). It signs
  requests with SAS tokens from `SASTokenCache`, pages through Atom feeds, limits concurrency and
  retries throttled requests. HTTP is behind `HTTPTransport` so tests can inject canned responses.
- **Messaging (helper):** `HelperMessagingClient` starts `swiftbus-helper` lazily from
  `Bundle.main/Contents/Helpers/swiftbus-helper` (`AppModel.helperURL`). Each request carries the
  connection string **over stdin** (never argv), so a crashed helper is restarted transparently on the
  next request with no handshake. Pending requests fail with `HelperError.exited` if it dies.
- **Queues vs subscriptions:** throughout the messaging API, `subscription == nil` means `topic` is
  actually a queue name. Keep that convention on both the Swift and C# side.
- **Resend semantics:** resend sends a copy to the **topic** (Service Bus cannot target one
  subscription), strips `DeadLetterReason`/`DeadLetterErrorDescription`, and completes the original only
  if the send succeeded. A resent message reaches every subscription whose filter matches.
- **Batching:** `DeadLetterActions.run` processes sequence numbers in batches (default 25), reports each
  batch via `onBatch` for progress UI, and turns a thrown batch into per-message failures so later
  batches still run.

### Helper protocol (JSON lines)

One JSON object per line on stdin, one response per line on stdout, matched by `id`. stderr is
diagnostics only (the app discards it). Keys are camelCase.

```jsonc
// request
{"id":"<uuid>","op":"peekDeadLetters","connectionString":"Endpoint=…","topic":"orders",
 "subscription":"billing","max":100,"fromSequence":null}
// response
{"id":"<uuid>","ok":true,"messages":[{ "sequenceNumber":42, "enqueuedTime":"…", "bodyBase64":"…", … }]}
{"id":"<uuid>","ok":false,"error":"…","errorCode":"unauthorized|notFound|throttled"}
```

Ops: `ping`, `connect`, `peekActive`, `peekDeadLetters`, `resend`, `delete`, `send`, `purge`. `resend`/`delete` take
`sequenceNumbers` and return per-message `results`. `send` (body, contentType, subject, messageId,
applicationProperties, count) and `purge` (`deadLetter` flag) return a `count`.

**When changing the protocol, update all of these together:**
`Helper/SwiftbusHelper/Protocol.cs` (DTOs + `ProtocolContext` for AOT), `Program.cs` (dispatch and
`errorCode` mapping), `HelperMessagingClient.swift` (`HelperRequest`/`HelperResponse`, error mapping),
`Messaging.swift` (protocol + models) and the fake helper in `HelperClientTests.swift`.

## Building and running

Prerequisites: Xcode (Swift 6) and the **.NET 10 SDK** (`dotnet` on `/opt/homebrew/bin`,
`/usr/local/share/dotnet` or `/usr/local/bin`).

```bash
# Package tests — the fastest feedback loop; no Azure or .NET needed
cd Packages/ServiceBusKit && swift test
```

```bash
# Build the whole app (also publishes and signs the helper via the build phase)
xcodebuild -project Swiftbus.xcodeproj -scheme Swiftbus -configuration Debug build
```

```bash
# Build the helper on its own to check C# changes
dotnet publish Helper/SwiftbusHelper/SwiftbusHelper.csproj -c Release -r osx-arm64 -o /tmp/swiftbus-helper
```

- Debug builds embed a helper for the host architecture; Release builds embed a universal (`lipo`)
  binary. `build-helper.sh` runs `dotnet` with a scrubbed environment (`env -i`) because Xcode exports
  variables MSBuild would otherwise read as properties — keep it that way.
- The helper is signed with `Helper/helper.entitlements` (`app-sandbox` + `inherit`). Without both,
  macOS refuses to launch it from the sandboxed app. Don't remove them.
- The app target has `ENABLE_USER_SCRIPT_SANDBOXING = NO` so the build phase can run `dotnet`.
- Regenerate the icon with `swift scripts/make-icon.swift`.
- Running the app against a real namespace needs a connection string with Manage, Send and Listen
  rights. Never commit connection strings or keys; tests must not hit Azure.

## Conventions

### Swift
- Swift 6 language mode with strict concurrency. Model types are `Sendable`; UI state lives in
  `@MainActor @Observable` classes (`AppModel`, `DeadLetterModel`); process/IO state lives in actors.
- Use Swift Concurrency (`async`/`await`, `Task`), not Combine or completion handlers.
- **Put logic in ServiceBusKit, not the app target**, whenever it does not need SwiftUI/AppKit. The
  package is where tests live; the app target has no test target.
- Depend on protocols at seams (`MessagingClient`, `HTTPTransport`) so code can be tested with fakes.
- Errors shown to users go through `ServiceBusError` / `HelperError` with a readable
  `errorDescription`. Messages should say what to check (e.g. which SAS right is missing).
- Secrets: connection strings go in the Keychain via `ConnectionStore`; only display names go in
  `UserDefaults`. Never log connection strings or keys, and never pass them as process arguments.
- The app target uses a file-system-synchronized group: new files under `Swiftbus/` are picked up
  automatically, no `project.pbxproj` edits needed. Avoid hand-editing `project.pbxproj` unless you
  must change build settings.
- Style: 4-space indent, doc comments (`///`) on public API explaining *why*, short `// MARK:`
  sections, no external Swift dependencies.

### C# helper
- Must stay **Native-AOT and trim safe**: no reflection-based JSON. Add every serialized type to
  `ProtocolContext` with `[JsonSerializable]`. `JsonSerializerIsReflectionEnabledByDefault` is false.
- Requests are handled one at a time; stdout is reserved for protocol responses (never
  `Console.WriteLine` diagnostics to stdout — use stderr).
- Map well-known failures to `errorCode` (`unauthorized`, `notFound`, `throttled`) so Swift can turn them
  into typed errors.
- Destructive operations must stay safe: receive in peek-lock mode, act only on the requested sequence
  numbers, abandon the rest, and complete a message only after a successful send.

### Tests
- Framework: **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), not XCTest.
- `ManagementClient` tests use a fake `HTTPTransport` with canned Atom XML.
- `HelperClientTests` use a tiny shell script as a fake helper (`fakeHelper(_:)`) — extend it when you
  add ops or fields, and test crash/restart behaviour there.
- Add or update tests in `Packages/ServiceBusKit/Tests` for every logic change, and run `swift test`
  before finishing. UI changes should at least build with `xcodebuild`.

## Working checklist for agents

1. Identify which layer the change belongs in (UI, ServiceBusKit, helper, or protocol across both).
2. Prefer adding logic to ServiceBusKit with tests over adding it to views.
3. If you touch the helper protocol, update both sides and the fake helper in the same change.
4. Run `swift test` in `Packages/ServiceBusKit`; build the app with `xcodebuild` when UI, project or
   helper files changed (requires the .NET SDK).
5. Keep secrets out of code, logs, argv and commits. Don't commit `bin/`, `obj/`, `DerivedData/`,
   `.build/` or `xcuserdata/` (already in `.gitignore`).
6. Update `README.md` when user-visible behaviour or build steps change, and this file when the
   structure or conventions change.
