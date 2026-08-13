# ZYLogKit

`ZYLogKit` is a small Swift Package for app logging infrastructure: console logging through Apple's unified logging system, daily file logs, retention cleanup, ZIP export, sessions, performance measurement, and attachments.

## Install

```swift
.package(url: "https://github.com/Horse888/ZYLogKit.git", from: "1.1.0")
```

```swift
.product(name: "ZYLogKit", package: "ZYLogKit")
```

## Basic Usage

```swift
import ZYLogKit

Log.info("App Launch")
Log.network("GET /user")
Log.database("Insert Word")
Log.error(error, category: .database)
```

`Log.debug` and `Log.trace` are ignored in Release builds. Warnings, errors, and critical logs still write in Release.

## Configure

```swift
Log.configure(LogConfiguration(
    subsystem: "com.example.app",
    retention: LogRetention(
        maximumAge: 7 * 24 * 60 * 60,
        maximumTotalSizeBytes: 20 * 1024 * 1024,
        maximumFileCount: 30
    ),
    fileWriting: LogFileWritingConfiguration(
        maximumPendingBytes: 1024 * 1024,
        batchSizeBytes: 64 * 1024,
        overflowStrategy: .dropOldest,
        synchronizesAfterLevel: .critical,
        fileProtection: .completeUntilFirstUserAuthentication,
        usesPrivateFilePermissions: true,
        excludesLogDirectoryFromBackup: true,
        internalErrorThrottleInterval: 60
    ),
    privacy: .default,
    outputLimits: LogOutputLimits(
        maximumMessageCharacters: 8 * 1024,
        maximumMetadataKeyCharacters: 256,
        maximumMetadataValueCharacters: 2 * 1024,
        maximumMetadataItemCount: 64,
        maximumFormattedLineCharacters: 16 * 1024
    ),
    formatter: LogFormatter(
        includesSourceLocation: true,
        includesMetadata: true
    ),
    internalErrorHandler: { message, error in
        print("[ZYLogKit] \(message)", error ?? "")
    },
    metadataProvider: {
        [
            "UserID": currentUserID,
            "Environment": "production"
        ]
    }
))
```

By default, logs are written to:

```text
Application Support/<bundle id>/Logs/yyyy-MM-dd.log
```

Each configured session starts with metadata such as session ID, OS, process name, bundle, version, and build.

## Safety And Reliability

ZYLogKit applies privacy protection by default. Common secrets in messages and metadata, such as tokens, passwords, authorization headers, API keys, cookies, credentials, and email addresses, are redacted before they reach console or file output.

```swift
Log.info(
    "Login token=abc123 user=user@example.com",
    metadata: ["apiKey": "secret", "RequestID": "visible"]
)
```

Output is bounded by default so a single oversized message, metadata key, or metadata value cannot grow log files unexpectedly. Configure `outputLimits` to tune or disable those caps. Metadata keys and values are normalized so control characters cannot split one event into multiple physical lines.

File-write failures are reported through `internalErrorHandler` instead of being silently ignored.
Metadata providers are guarded against recursive evaluation, so a provider that emits a log entry does not recurse until the app exhausts its stack.
`metadataProvider` can be evaluated concurrently on caller threads, so any mutable state it captures must be synchronized. `internalErrorHandler` is delivered serially on a utility queue.

## Concurrent File Writing

`Log` can be called concurrently from any thread. Producers format events concurrently, then enqueue them into a bounded buffer. A single utility-priority writer owns the file descriptor and writes entries in batches so lines remain ordered and cannot corrupt each other.

The default pending buffer is 1 MB and the default write batch is 64 KB. When the buffer is full, the oldest pending entries are dropped and a throttled `internalErrorHandler` callback reports the loss. Choose `.dropNewest` when preserving older events is more important. Critical entries are synchronized to storage by default; set `synchronizesAfterLevel` to `nil` to disable level-triggered synchronization.

Setting `maximumPendingBytes` to `nil` removes backpressure. Keep a finite limit in production unless the app has a stronger process-wide memory budget.

Log files use private POSIX permissions, use data protection until first user authentication on supported Apple platforms, and are excluded from device backups by default. These policies are configurable through `LogFileWritingConfiguration`.

For lifecycle paths where blocking is undesirable:

```swift
Log.flushAsync {
    // All entries queued before the flush have reached the file writer.
}
```

The flush completion is delivered on `completionQueue`, which defaults to the main queue.

## Resource Monitoring

`Log.configure` starts automatic resource monitoring by default. Every 30 seconds, ZYLogKit records the current app process CPU and memory usage:

```text
2026-07-03 23:00:00.000 +08:00 ℹ️ INFO RESOURCE Log.swift:459 recordAutomaticResourceUsage(_:monitoring:file:function:line:) - Resource Usage {app=Example 1.0(100) device=iPad OS 27.0 resource.cpu.percent=3.2 resource.memory.resident.mb=86.4 resource.memory.physical_footprint.mb=94.1}
```

Per-line logs omit repeated session and process fields. App and device metadata are compacted into `app=Name Version(Build)` and `device=Model OS Version` when those keys are present.

You can change the interval or disable it:

```swift
Log.configure(LogConfiguration(
    resourceMonitoring: LogResourceMonitoringConfiguration(interval: 15)
))

Log.configure(LogConfiguration(
    resourceMonitoring: .disabled
))
```

Non-finite or non-positive intervals disable the timer. Positive intervals are constrained to the safe range from 0.1 seconds to one year.

You can also record a sample manually at important points:

```swift
Log.recordResourceUsage()
```

## Export

```swift
let zipURL = try Log.export()
```

ZIP exports use streaming DEFLATE compression by default. Log files are read in fixed-size chunks instead of loading an entire file into memory. The destination is replaced only after a complete archive has been synchronized successfully.

```swift
let options = LogExportConfiguration(
    compression: .deflate,
    includesAttachments: true,
    maximumFileCount: 10_000,
    maximumUncompressedSizeBytes: 256 * 1024 * 1024,
    fileProtection: .completeUntilFirstUserAuthentication,
    usesPrivateFilePermissions: true
)

let zipURL = try Log.export(configuration: options)
```

Use `compression: .none` when export speed matters more than archive size, or `includesAttachments: false` when an export should contain only text logs. Limits can be set to `nil`, subject to the ZIP32 format limit.

Archive discovery skips hidden files, symbolic links, and non-regular files. Unsafe cross-platform path components are rejected instead of being written to the ZIP.

Compression can run away from the main thread with the completion delivered on a queue you choose:

```swift
Log.exportAsync(configuration: options) { result in
    // The default completion queue is the main queue.
}
```

The exported ZIP contains:

```text
logs/
  2026-07-03.log
  attachments/
```

You can pass `zipURL` directly to `UIActivityViewController`.

## Performance

```swift
Log.begin("Download")
// work
Log.end("Download")

let pdf = try Log.measure("Export PDF") {
    try exporter.export()
}
```

## Attachments

```swift
try Log.attach(data: imageData, filename: "screenshot.png")
try Log.attach(file: databaseURL)
```
