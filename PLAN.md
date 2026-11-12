# Swiftbus — plan

A native macOS app for finding and fixing dead-lettered messages in Azure Service Bus topics. It is
modelled on [Service Bus Explorer](https://github.com/paolosalvatori/ServiceBusExplorer), but covers
only the part used day to day: connect to a namespace, see which subscriptions have dead-letters,
inspect the failed messages, and resend them.

## Scope of the first version

- Connect to a namespace with a **connection string**. Saved connections are kept in the Keychain.
- List all topics and their subscriptions with active, dead-letter and transfer-dead-letter counts.
  By default, only show topics and subscriptions that have dead-letters.
- Open a subscription's dead-letter queue and see the messages with their reason, error
  description, enqueued time, delivery count, properties and body.
- **Resend** selected messages, then remove the originals from the dead-letter queue. Delete them
  without resending as a secondary option.

Not in the first version: Microsoft Entra ID sign-in, queues, editing messages before resending,
export, purge, and creating or editing entities.

## Architecture

```
┌──────────────────────────── Swiftbus.app ─────────────────────────────┐
│  SwiftUI views                                                        │
│      │                                                                │
│  ServiceBusKit (Swift package)                                        │
│   ├─ ConnectionString, SAS token signing (CryptoKit)                  │
│   ├─ ManagementClient ── REST/Atom ──► topics, subscriptions, counts  │
│   └─ MessagingClient ─── JSON over stdin/stdout ──┐                   │
│                                                   ▼                   │
│  Contents/Helpers/swiftbus-helper  (.NET 10, Native AOT)              │
│   └─ Azure.Messaging.ServiceBus ── AMQP ──► peek / send / delete      │
└───────────────────────────────────────────────────────────────────────┘
```

Microsoft has no Service Bus SDK for Swift, and the REST API cannot peek at messages without locking
them (every unlock raises the delivery count). The work is split:

- **Listing topics, subscriptions and counts: pure Swift over REST.** The management API returns
  each subscription as an Atom XML entry including its `CountDetails`. It only needs a SAS token, so
  refreshes are fast and need no helper.
- **Reading and resending messages: a bundled .NET helper.** A small .NET 10 console app using
  `Azure.Messaging.ServiceBus`, built with Native AOT and bundled inside the `.app`. Swift starts it
  as a child process and talks to it in line-delimited JSON over stdin/stdout. It gives real peek,
  delete by sequence number, and properties copied correctly on resend, using the same SDK that
  Service Bus Explorer uses.

The UI only talks to a `MessagingClient` protocol, so the helper could later be replaced by a pure
Swift AMQP client without touching the UI.

## Implementation steps

1. **Project skeleton.** A SwiftUI macOS app (macOS 14 or later) plus a local Swift package
   `ServiceBusKit` for all non-UI logic and its tests. App Sandbox with outgoing network access only.
2. **Connection strings and auth.** Parse `Endpoint`, `SharedAccessKeyName`, `SharedAccessKey` and
   the optional `EntityPath`. Generate SAS tokens (HMAC-SHA256 over the URL-encoded resource and
   expiry) and cache them until shortly before they expire. A connection sheet with a "Test
   connection" button. Secrets in the Keychain, display names in UserDefaults.
3. **Management client (REST).**
   - `GET https://{ns}/$Resources/Topics?api-version=2021-05&$skip=&$top=100`, paging until done.
   - `GET https://{ns}/{topic}/Subscriptions?api-version=2021-05`, paging too (some topics have
     hundreds of subscriptions).
   - Read `ActiveMessageCount`, `DeadLetterMessageCount`, `TransferDeadLetterMessageCount` and the
     status from the XML with `XMLParser`.
   - Fetch topics in parallel with a cap of about 8 concurrent requests.
4. **Main window.** A three-column `NavigationSplitView`:
   - **Sidebar:** topics with a red badge for their total dead-letter count, a search field, and an
     "Only with dead-letters" toggle that is on by default. An **All dead-letters** item at the top
     lists every failing subscription across all topics.
   - **Middle:** a subscription table with name, active, dead-letter and transfer-dead-letter counts,
     sorted by dead-letters first.
   - **Toolbar:** refresh (⌘R), optional auto-refresh every 30 or 60 seconds, and a "last refreshed"
     time.
5. **.NET helper.** A .NET 10 console app with Native AOT, bundled in `Contents/Helpers` by an Xcode
   build phase. One JSON request per line on stdin, one JSON response per line on stdout, matched by
   request id. Operations:
   - `peekDeadLetters(topic, subscription, max, fromSequence)`
   - `resend(topic, subscription, sequenceNumbers)` — receive the matching dead-letters, send a copy
     to the topic, and complete the original only after the send succeeds.
   - `delete(topic, subscription, sequenceNumbers)`
   - `peekActive` (optional)

   The Swift side launches the helper lazily, passes the connection string through stdin (never on
   the command line), and restarts it if it exits.
6. **Dead-letter detail view.**
   - A message table with sequence number, enqueued time, reason, error description, message ID,
     subject and delivery count.
   - An inspector showing the body (pretty-printed JSON or XML, raw text otherwise) and the system
     and application properties, with copy buttons.
   - Group by reason, so many identical failures show as one row.
7. **Resend flow.**
   - Select messages and confirm. For each message, copy the body, content type, correlation ID,
     subject and application properties, minus the `DeadLetter*` properties.
   - Send the copy to the topic, then remove the original from the dead-letter queue only after the
     send succeeds.
   - Show progress and success or failure per message, then refresh the counts.
   - This matches Service Bus Explorer's `MessageForm` (copy, send, then remove by sequence number).
8. **Polish.** An activity log drawer, clear errors for 401 and 404 responses and throttling,
   keyboard shortcuts, empty and loading states, an app icon, and signing and notarization if the
   app is shared.

## Testing

- **Unit tests** for connection-string parsing, SAS token generation (against a known token), and
  Atom XML parsing (against saved real responses).
- **Helper tests** for the JSON protocol: request and response encoding, and error reporting.
- **Integration tests** against a dev namespace, enabled by an environment variable holding a
  connection string. Dead-letter a test message, check it shows up, resend it, and check the count
  drops.

## Caveat: resend goes to the whole topic

Service Bus can't send to a single subscription, only to the topic. A resent message is delivered to
every subscription whose filter matches it, not just the one it came from. Service Bus Explorer
behaves the same way. If each subscription filters on something unique (such as an integration ID),
this is harmless. If several subscriptions on a topic can match the same message, resend creates
duplicates there, so the resend confirmation should warn about it.

## Later

Microsoft Entra ID sign-in, queues, edit-then-resend, export to file, purging dead-letter queues,
and possibly a pure Swift AMQP client to replace the helper.
