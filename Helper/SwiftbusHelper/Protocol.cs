using System.Text.Json.Serialization;

namespace SwiftbusHelper;

/// One request per line on stdin. Which fields are used depends on <see cref="Op"/>.
public sealed class Request
{
    public string Id { get; set; } = "";
    /// connect | peekDeadLetters | peekTransferDeadLetters | peekActive | resend | delete | send | purge | ping
    public string Op { get; set; } = "";
    public string? ConnectionString { get; set; }
    public string? Topic { get; set; }
    public string? Subscription { get; set; }
    public int? Max { get; set; }
    public long? FromSequence { get; set; }
    public List<long>? SequenceNumbers { get; set; }
    // send: Topic is the queue or topic to send to. Body is UTF-8 text.
    public string? Body { get; set; }
    public string? ContentType { get; set; }
    public string? Subject { get; set; }
    public string? MessageId { get; set; }
    /// send: typed application properties.
    public List<PropertyDto>? Properties { get; set; }
    /// purge, delete: true (the default for delete) targets the dead-letter queue, false the active messages.
    public bool? DeadLetter { get; set; }
}

/// One response per line on stdout, matched to its request by <see cref="Id"/>.
public sealed class Response
{
    public string Id { get; set; } = "";
    public bool Ok { get; set; }
    public string? Error { get; set; }
    /// unauthorized | notFound | throttled, when the failure is one of these well-known cases.
    public string? ErrorCode { get; set; }
    public List<MessageDto>? Messages { get; set; }
    public List<ItemResult>? Results { get; set; }
    /// send: messages sent. purge: messages deleted.
    public int? Count { get; set; }
}

/// A typed application property to send. Type is a .NET type name such as Int32 or Guid; Value is its text form.
public sealed class PropertyDto
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "String";
    public string Value { get; set; } = "";
}

public sealed class ItemResult
{
    public long SequenceNumber { get; set; }
    public bool Ok { get; set; }
    public string? Error { get; set; }
}

public sealed class MessageDto
{
    public long SequenceNumber { get; set; }
    public string? MessageId { get; set; }
    public DateTimeOffset EnqueuedTime { get; set; }
    public int DeliveryCount { get; set; }
    public string? Subject { get; set; }
    public string? ContentType { get; set; }
    public string? CorrelationId { get; set; }
    public string? DeadLetterReason { get; set; }
    public string? DeadLetterErrorDescription { get; set; }
    /// Body decoded as UTF-8 when valid, otherwise null (see <see cref="BodyBase64"/>).
    public string? Body { get; set; }
    public string BodyBase64 { get; set; } = "";
    public Dictionary<string, string> ApplicationProperties { get; set; } = new();
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(Request))]
[JsonSerializable(typeof(Response))]
internal partial class ProtocolContext : JsonSerializerContext { }
