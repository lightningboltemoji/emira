import EmiraCore

// Driving a `State` to rest, without a clock. Fixtures build worlds out of `windowCreated`s, which
// animate, so they must close the transition the way the daemon does rather than assume instant
// placement.

/// Answer every outstanding capture, land every AX set, and tick until the animators settle. Bounded,
/// so a spring that never converges fails the test loudly instead of hanging the suite.
@MainActor
func settled(_ start: State, _ effects: [Effect] = []) -> State {
    var s = start
    var queue = effects
    for _ in 0..<4000 {
        var feedback: [Event] = []
        for effect in queue {
            switch effect {
            case .capture(let w, _): feedback.append(.captureReady(w))
            case .setFrame(let w, _), .park(let w, _): feedback.append(.axLanded(w))
            default: continue
            }
        }
        queue = []
        if feedback.isEmpty {
            guard s.motion.isTransitioning else { return s }
            feedback = [.tick(dt: 1.0 / 120)]
        }
        for event in feedback {
            let (next, out) = Engine.reduce(s, event)
            s = next
            queue += out
        }
    }
    return s
}

/// Fold one event into a state and drive whatever it started to rest.
@MainActor
func settledAfter(_ s: State, _ event: Event) -> State {
    let (next, effects) = Engine.reduce(s, event)
    return settled(next, effects)
}
