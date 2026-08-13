import Foundation

final class ResourceMonitor {
    private let configuration: LogResourceMonitoringConfiguration
    private let handler: (ResourceUsageSnapshot) -> Void
    private let queue = DispatchQueue(label: "com.zylogkit.resource-monitor")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?

    init(
        configuration: LogResourceMonitoringConfiguration,
        handler: @escaping (ResourceUsageSnapshot) -> Void
    ) {
        self.configuration = configuration
        self.handler = handler
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() {
        guard configuration.isEnabled,
              configuration.interval.isFinite,
              configuration.interval > 0 else {
            return
        }

        performSynchronously {
            guard timer == nil else {
                return
            }

            let interval = min(
                max(configuration.interval, Self.minimumInterval),
                Self.maximumInterval
            )
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [handler] in
                guard let snapshot = ResourceUsageSnapshot.current() else {
                    return
                }
                handler(snapshot)
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        performSynchronously {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        stop()
    }

    private func performSynchronously(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private static let minimumInterval: TimeInterval = 0.1
    private static let maximumInterval: TimeInterval = 365 * 24 * 60 * 60
}
