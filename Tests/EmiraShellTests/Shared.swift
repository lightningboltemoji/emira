/// A value a test hands to a subsystem's closure and changes afterwards. A `@MainActor` closure is
/// `@Sendable`, and Swift flags a captured local `var` mutated after the capture; a reference is not.
@MainActor
final class Shared<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
