# ZYLogKit

`ZYLogKit` is a small Swift Package for app logging infrastructure: console logging through Apple's unified logging system, daily file logs, retention cleanup, ZIP export, sessions, performance measurement, and attachments.

## Install

```swift
.package(url: "https://github.com/Horse888/ZYLogKit.git", from: "1.0.3")
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
    privacy: .default,
    outputLimits: LogOutputLimits(
        maximumMessageCharacters: 8 * 1024,
        maximumMetadataKeyCharacters: 256,
        maximumMetadataValueCharacters: 2 * 1024,
        maximumMetadataItemCount: 64,
        maximumFormattedLineCharacters: 16 * 1024
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

You can also record a sample manually at important points:

```swift
Log.recordResourceUsage()
```

## Export

```swift
let zipURL = try Log.export()
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
