using System.Text.Json;
using Azure.Messaging.ServiceBus;
using SwiftbusHelper;

// Protocol: one JSON request per line on stdin, one JSON response per line on stdout.
// Requests are handled one at a time. stderr is for diagnostics only.
var stdout = new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
var stdin = new StreamReader(Console.OpenStandardInput(), new System.Text.UTF8Encoding(false));
await using var operations = new Operations();

while (await stdin.ReadLineAsync() is { } line)
{
    if (string.IsNullOrWhiteSpace(line)) continue;
    var response = new Response();
    try
    {
        var request = JsonSerializer.Deserialize(line, ProtocolContext.Default.Request)
                      ?? throw new ArgumentException("Empty request");
        response.Id = request.Id;
        if (request.ConnectionString is { } cs) await operations.ConnectAsync(cs);
        switch (request.Op)
        {
            case "ping": break;
            case "connect":
                if (request.ConnectionString is null) throw new ArgumentException("connectionString is required");
                break;
            case "peekActive": response.Messages = await operations.PeekActiveAsync(request); break;
            case "peekDeadLetters": response.Messages = await operations.PeekDeadLettersAsync(request); break;
            case "peekTransferDeadLetters": response.Messages = await operations.PeekTransferDeadLettersAsync(request); break;
            case "resend": response.Results = await operations.ResendAsync(request); break;
            case "delete": response.Results = await operations.DeleteAsync(request); break;
            case "send": response.Count = await operations.SendAsync(request); break;
            case "purge": response.Count = await operations.PurgeAsync(request); break;
            default: throw new ArgumentException($"Unknown op '{request.Op}'");
        }
        response.Ok = true;
    }
    catch (Exception ex)
    {
        response.Ok = false;
        response.Error = ex.Message;
        response.ErrorCode = ex switch
        {
            UnauthorizedAccessException => "unauthorized",
            ServiceBusException { Reason: ServiceBusFailureReason.MessagingEntityNotFound } => "notFound",
            ServiceBusException { Reason: ServiceBusFailureReason.ServiceBusy or ServiceBusFailureReason.QuotaExceeded } => "throttled",
            _ => null
        };
    }
    await stdout.WriteLineAsync(JsonSerializer.Serialize(response, ProtocolContext.Default.Response));
}
