# Changelog

## [1.1.0] - 2026-08-13

### Added

- Bounded, batched file writing with configurable pending bytes, batch size, overflow policy, synchronization level, and internal-error throttling.
- An asynchronous flush API alongside the existing synchronous flush operation.
- Configurable DEFLATE or stored ZIP export, attachment inclusion, export size limits, and asynchronous export completion.
- Configurable `LogFormatter` support through `LogConfiguration`.

### Changed

- Log producers can write concurrently while one utility-priority file writer preserves line ordering.
- Long write bursts yield between bounded drain turns so flush, close, and retention work cannot be starved.
- ZIP export now compresses files in fixed-size chunks instead of loading complete files into memory.
- Filtered messages are no longer evaluated when no enabled destination accepts their level.
- Unified logging objects are reused through a bounded subsystem/category cache.
- Shared logger state now has one lock-audited boundary and passes Swift 6 complete concurrency checking.

### Fixed

- Internal error handlers can call `Log.flush()` without deadlocking the file writer.
- Resource monitoring can stop from its own callback, and extreme timer intervals are normalized safely.
- Concurrent configuration and monitor-stop operations cannot leave an unowned resource timer running.
- Resource snapshots release every Mach thread port returned by `task_threads`.
- Metadata providers can emit logs without recursively evaluating themselves.
- Failed exports preserve an existing destination archive and remove partial output.
- ZIP32 count, path, size, offset, and timestamp boundaries now fail with errors instead of trapping.
- Concurrent attachment writes cannot collide or escape their session directory through special filenames.

### Security

- Log and archive files use private permissions and configurable Apple file protection.
- Log directories are excluded from device backups by default.
- Archive input rejects symbolic links and non-regular files.
- Archive paths reject backslashes, traversal components, and control characters.
- Attachment filenames and sensitive metadata keys are pre-bounded before normalization.
- Session headers no longer include the device host name by default.
