// Preserves pre-Sendable callback APIs while crossing DispatchQueue boundaries internally.
final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
