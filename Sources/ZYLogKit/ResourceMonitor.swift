import Foundation

final class ResourceMonitor {
    private let configuration: LogResourceMonitoringConfiguration
    private let handler: (ResourceUsageSnapshot) -> Void
    private let queue = DispatchQueue(label: "com.zylogkit.resource-monitor")
    private var timer: DispatchSourceTimer?

    init(
        configuration: LogResourceMonitoringConfiguration,
        handler: @escaping (ResourceUsageSnapshot) -> Void
    ) {
        self.configuration = configuration
        self.handler = handler
    }

    func start() {
        guard configuration.isEnabled, configuration.interval > 0 else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.interval, repeating: configuration.interval)
        timer.setEventHandler { [handler] in
            guard let snapshot = ResourceUsageSnapshot.current() else {
                return
            }
            handler(snapshot)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        stop()
    }
}
