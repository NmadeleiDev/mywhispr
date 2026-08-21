/// Carries a value the compiler cannot prove is `Sendable` across an isolation
/// boundary, where ownership has already been established some other way.
///
/// Used only for Objective-C audio types that are not Sendable-audited but are
/// genuinely exclusively owned at the point of transfer — always paired with a
/// `sending` parameter, which is what actually proves the ownership. On its own this
/// box proves nothing, so it should never be reached for to silence a warning.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
