# ZYLogKit

`ZYLogKit` is a small Swift Package for app logging infrastructure: console logging through Apple's unified logging system, daily file logs, retention cleanup, ZIP export, sessions, performance measurement, and attachments.

## Install

```swift
.package(url: "https://github.com/zzymoon/ZYLogKit.git", from: "1.0.0")
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
