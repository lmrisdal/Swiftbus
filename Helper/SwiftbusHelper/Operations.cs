using System.Text;
using Azure.Messaging.ServiceBus;

namespace SwiftbusHelper;

/// Service Bus operations behind the JSON protocol.
public sealed class Operations : IAsyncDisposable
{
    private ServiceBusClient? _client;
    private string? _connectionString;

    private ServiceBusClient Client => _client ?? throw new InvalidOperationException("Not connected. Send a 'connect' request first.");

    public async Task ConnectAsync(string connectionString)
    {
        if (_client is not null && _connectionString == connectionString) return;
        if (_client is not null) await _client.DisposeAsync();
        _client = new ServiceBusClient(connectionString);
        _connectionString = connectionString;
    }

    /// With no subscription, `Topic` holds the name of a queue.
    private ServiceBusReceiver DeadLetterReceiver(Request r, ServiceBusReceiveMode mode, SubQueue subQueue = SubQueue.DeadLetter)
    {
        var options = new ServiceBusReceiverOptions { SubQueue = subQueue, ReceiveMode = mode };
        return string.IsNullOrWhiteSpace(r.Subscription)
            ? Client.CreateReceiver(Require(r.Topic, "topic"), options)
            : Client.CreateReceiver(Require(r.Topic, "topic"), r.Subscription, options);
    }

    public Task<List<MessageDto>> PeekDeadLettersAsync(Request r) => PeekAsync(r, SubQueue.DeadLetter);

    /// Peeks the transfer dead-letter queue: messages that failed while being forwarded to another entity.
    public Task<List<MessageDto>> PeekTransferDeadLettersAsync(Request r) => PeekAsync(r, SubQueue.TransferDeadLetter);

    /// Peeks the subscription's active messages. Peeking takes no lock and does not change delivery counts.
    public Task<List<MessageDto>> PeekActiveAsync(Request r) => PeekAsync(r, SubQueue.None);

    private async Task<List<MessageDto>> PeekAsync(Request r, SubQueue subQueue)
    {
        await using var receiver = DeadLetterReceiver(r, ServiceBusReceiveMode.PeekLock, subQueue);
        var max = Math.Clamp(r.Max ?? 100, 1, 1000);
        var messages = new List<MessageDto>();
        var from = r.FromSequence ?? 0;
        while (messages.Count < max)
        {
            var batch = await receiver.PeekMessagesAsync(max - messages.Count, from > 0 ? from : null);
            if (batch.Count == 0) break;
            messages.AddRange(batch.Select(ToDto));
            from = batch[^1].SequenceNumber + 1;
        }
        return messages;
    }

    /// Copies each requested dead-letter to the topic, then completes the original only if the send succeeded.
    public async Task<List<ItemResult>> ResendAsync(Request r)
    {
        var topic = Require(r.Topic, "topic");
        await using var sender = Client.CreateSender(topic);
        return await ProcessAsync(r, async (receiver, message) =>
        {
            var copy = new ServiceBusMessage(message);
            copy.ApplicationProperties.Remove("DeadLetterReason");
            copy.ApplicationProperties.Remove("DeadLetterErrorDescription");
            await sender.SendMessageAsync(copy);
            await receiver.CompleteMessageAsync(message);
        });
    }

    /// Deletes the requested messages from the dead-letter queue, or from the active queue when
    /// `DeadLetter` is false. Active messages we skip over are abandoned, which counts as a delivery attempt.
    public Task<List<ItemResult>> DeleteAsync(Request r) =>
        ProcessAsync(r, (receiver, message) => receiver.CompleteMessageAsync(message),
                     r.DeadLetter == false ? SubQueue.None : SubQueue.DeadLetter);

    /// Receives messages in peek-lock mode until every requested sequence number has been handled
    /// or the queue yields nothing more. Messages we don't want are abandoned (lock released).
    private async Task<List<ItemResult>> ProcessAsync(Request r, Func<ServiceBusReceiver, ServiceBusReceivedMessage, Task> action,
                                                      SubQueue subQueue = SubQueue.DeadLetter)
    {
        var wanted = new HashSet<long>(r.SequenceNumbers ?? throw new ArgumentException("sequenceNumbers is required"));
        var results = new List<ItemResult>();
        await using var receiver = DeadLetterReceiver(r, ServiceBusReceiveMode.PeekLock, subQueue);
        var emptyRounds = 0;
        while (wanted.Count > 0 && emptyRounds < 2)
        {
            var batch = await receiver.ReceiveMessagesAsync(100, TimeSpan.FromSeconds(3));
            if (batch.Count == 0) { emptyRounds++; continue; }
            emptyRounds = 0;
            foreach (var message in batch)
            {
                if (!wanted.Remove(message.SequenceNumber))
                {
                    await receiver.AbandonMessageAsync(message);
                    continue;
                }
                try
                {
                    await action(receiver, message);
                    results.Add(new ItemResult { SequenceNumber = message.SequenceNumber, Ok = true });
                }
                catch (Exception ex)
                {
                    try { await receiver.AbandonMessageAsync(message); } catch { /* lock may be gone */ }
                    results.Add(new ItemResult { SequenceNumber = message.SequenceNumber, Ok = false, Error = ex.Message });
                }
            }
        }
        results.AddRange(wanted.Select(s => new ItemResult
        {
            SequenceNumber = s, Ok = false, Error = subQueue == SubQueue.None
                ? "Message not found in the active queue (already received?)."
                : "Message not found in the dead-letter queue (already handled?)."
        }));
        return results;
    }

    /// Sends one text message to a queue or topic.
    public async Task<int> SendAsync(Request r)
    {
        await using var sender = Client.CreateSender(Require(r.Topic, "topic"));
        var m = new ServiceBusMessage(r.Body ?? "")
        {
            ContentType = string.IsNullOrWhiteSpace(r.ContentType) ? null : r.ContentType,
            Subject = string.IsNullOrWhiteSpace(r.Subject) ? null : r.Subject,
            MessageId = string.IsNullOrWhiteSpace(r.MessageId) ? Guid.NewGuid().ToString() : r.MessageId
        };
        foreach (var p in r.Properties ?? new()) m.ApplicationProperties[p.Name] = ParseProperty(p);
        await sender.SendMessageAsync(m);
        return 1;
    }

    /// Converts a property's text to the .NET value type it names, so receivers see a typed value.
    static object ParseProperty(PropertyDto p)
    {
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var v = p.Value;
        try
        {
            return p.Type switch
            {
                "Boolean" => bool.Parse(v.Trim()),
                "Byte" => byte.Parse(v.Trim(), inv),
                "SByte" => sbyte.Parse(v.Trim(), inv),
                "Int16" => short.Parse(v.Trim(), inv),
                "UInt16" => ushort.Parse(v.Trim(), inv),
                "Int32" => int.Parse(v.Trim(), inv),
                "UInt32" => uint.Parse(v.Trim(), inv),
                "Int64" => long.Parse(v.Trim(), inv),
                "UInt64" => ulong.Parse(v.Trim(), inv),
                "Single" => float.Parse(v.Trim(), inv),
                "Double" => double.Parse(v.Trim(), inv),
                "Decimal" => decimal.Parse(v.Trim(), inv),
                "Guid" => Guid.Parse(v.Trim()),
                "DateTime" => DateTime.Parse(v.Trim(), inv, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal),
                "Char" => v.Length == 1 ? v[0] : throw new FormatException("expected a single character"),
                _ => v
            };
        }
        catch (Exception ex) when (ex is FormatException or OverflowException)
        {
            throw new ArgumentException($"Property '{p.Name}': '{v}' is not a valid {p.Type}.");
        }
    }

    /// Deletes every message in the queue/subscription (or its dead-letter queue) by receiving in
    /// receive-and-delete mode until it yields nothing. Irreversible; the UI confirms first.
    public async Task<int> PurgeAsync(Request r)
    {
        var subQueue = r.DeadLetter == true ? SubQueue.DeadLetter : SubQueue.None;
        await using var receiver = DeadLetterReceiver(r, ServiceBusReceiveMode.ReceiveAndDelete, subQueue);
        var purged = 0;
        while (true)
        {
            var batch = await receiver.ReceiveMessagesAsync(500, TimeSpan.FromSeconds(2));
            if (batch.Count == 0) return purged;
            purged += batch.Count;
        }
    }

    private static MessageDto ToDto(ServiceBusReceivedMessage m)
    {
        var bytes = m.Body.ToArray();
        string? text = null;
        try { text = new UTF8Encoding(false, true).GetString(bytes); } catch (ArgumentException) { }
        return new MessageDto
        {
            SequenceNumber = m.SequenceNumber,
            MessageId = m.MessageId,
            EnqueuedTime = m.EnqueuedTime,
            DeliveryCount = m.DeliveryCount,
            Subject = m.Subject,
            ContentType = m.ContentType,
            CorrelationId = m.CorrelationId,
            DeadLetterReason = m.DeadLetterReason,
            DeadLetterErrorDescription = m.DeadLetterErrorDescription,
            Body = text,
            BodyBase64 = Convert.ToBase64String(bytes),
            ApplicationProperties = m.ApplicationProperties.ToDictionary(p => p.Key, p => Convert.ToString(p.Value, System.Globalization.CultureInfo.InvariantCulture) ?? "")
        };
    }

    private static string Require(string? value, string name) =>
        string.IsNullOrWhiteSpace(value) ? throw new ArgumentException($"{name} is required") : value;

    public async ValueTask DisposeAsync()
    {
        if (_client is not null) await _client.DisposeAsync();
    }
}
