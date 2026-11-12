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

    public Task<List<ItemResult>> DeleteAsync(Request r) =>
        ProcessAsync(r, (receiver, message) => receiver.CompleteMessageAsync(message));

    /// Receives dead-letters in peek-lock mode until every requested sequence number has been handled
    /// or the queue yields nothing more. Messages we don't want are abandoned (lock released).
    private async Task<List<ItemResult>> ProcessAsync(Request r, Func<ServiceBusReceiver, ServiceBusReceivedMessage, Task> action)
    {
        var wanted = new HashSet<long>(r.SequenceNumbers ?? throw new ArgumentException("sequenceNumbers is required"));
        var results = new List<ItemResult>();
        await using var receiver = DeadLetterReceiver(r, ServiceBusReceiveMode.PeekLock);
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
            SequenceNumber = s, Ok = false, Error = "Message not found in the dead-letter queue (already handled?)."
        }));
        return results;
    }

    /// Sends `Count` copies of a text message to a queue or topic, in as few batches as fit.
    public async Task<int> SendAsync(Request r)
    {
        var count = Math.Clamp(r.Count ?? 1, 1, 1000);
        await using var sender = Client.CreateSender(Require(r.Topic, "topic"));
        ServiceBusMessage Build()
        {
            var m = new ServiceBusMessage(r.Body ?? "")
            {
                ContentType = string.IsNullOrWhiteSpace(r.ContentType) ? null : r.ContentType,
                Subject = string.IsNullOrWhiteSpace(r.Subject) ? null : r.Subject,
                MessageId = string.IsNullOrWhiteSpace(r.MessageId) ? Guid.NewGuid().ToString() : r.MessageId
            };
            foreach (var (key, value) in r.ApplicationProperties ?? new()) m.ApplicationProperties[key] = value;
            return m;
        }
        var sent = 0;
        var batch = await sender.CreateMessageBatchAsync();
        for (var i = 0; i < count; i++)
        {
            var message = Build();
            if (!batch.TryAddMessage(message))
            {
                if (batch.Count == 0) throw new ArgumentException("The message is too large to send.");
                await sender.SendMessagesAsync(batch);
                sent += batch.Count;
                batch.Dispose();
                batch = await sender.CreateMessageBatchAsync();
                if (!batch.TryAddMessage(message)) throw new ArgumentException("The message is too large to send.");
            }
        }
        if (batch.Count > 0) { await sender.SendMessagesAsync(batch); sent += batch.Count; }
        batch.Dispose();
        return sent;
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
