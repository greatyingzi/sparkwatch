import Foundation

/// One answer to "can the stored dashboard session be used?", plus the wait that
/// depends on it.
///
/// Why this type exists (measured 2026-10-16, both DGX boxes dark for hours):
/// the sign-in wait used to test a *different* condition than the guard that sent
/// it there — the guard required `token != nil && expiry > now`, the wait's exit
/// test was only `token != nil`. A token that was present but **expired**
/// therefore satisfied the exit test on the first pass, the loop `continue`d
/// without ever suspending, and each node burned a full core (≈200 % for the
/// pair, macOS filed its own `cpu_resource` diagnostic). Because that loop never
/// yielded, it also took the actor with it: the SSH probe — which needs no
/// credential at all — starved too, so "no data" looked like a network fault.
///
/// The rule this file encodes: **a place that waits for something must exit on
/// exactly the condition that made it wait.** `CredentialGate` is the single
/// predicate; `CredentialWait` is the only waiter.
public struct CredentialState: Sendable, Equatable {
    public var token: String?
    public var expiry: Date?

    public init(token: String? = nil, expiry: Date? = nil) {
        self.token = token
        self.expiry = expiry
    }

    public static let none = CredentialState()
}

public enum CredentialGate {
    /// The user-facing reason. One string, so the collector, the health rules and
    /// the status bar cannot describe the same state three different ways.
    public static let needsLoginReason = "未登录（需要 Dashboard 账号密码）"

    /// True only for a token that is present *and* provably unexpired.
    ///
    /// An unparseable expiry (`expiry == nil`) is **not** usable: the collector
    /// cannot prove the token will authenticate, and guessing "probably fine"
    /// is what put a stale token into the request path in the first place.
    public static func isUsable(token: String?, expiry: Date?, now: Date = Date()) -> Bool {
        guard let token, !token.isEmpty else { return false }
        guard let expiry else { return false }
        return expiry > now
    }

    public static func isUsable(_ state: CredentialState, now: Date = Date()) -> Bool {
        isUsable(token: state.token, expiry: state.expiry, now: now)
    }
}

public enum CredentialWait {
    /// How long one pass of the wait sleeps. Never zero by contract: a wait that
    /// does not suspend is a busy loop, and this one holds an actor while it runs.
    public static let passSeconds: Double = 1

    /// Should a pass stop waiting? Exactly `CredentialGate`'s question — the
    /// asymmetry between this and the guard is the bug described above.
    public static func passIsDone(_ state: CredentialState, now: Date = Date()) -> Bool {
        CredentialGate.isUsable(state, now: now)
    }

    /// Waits, one suspended pass at a time, until the read state is usable or the
    /// caller is no longer running. Returns the usable state, or nil when the wait
    /// ended because the runtime stopped.
    ///
    /// The hooks exist so the loop's two contracts can be tested without a box:
    /// it must ask the *same* question as the gate, and it must yield on every
    /// pass.
    public static func until(
        reading: @Sendable () async -> CredentialState,
        running: @Sendable () async -> Bool,
        sleep: @Sendable (Double) async -> Void,
        now: @Sendable () -> Date = { Date() }
    ) async -> CredentialState? {
        while await running() {
            let state = await reading()
            if passIsDone(state, now: now()) { return state }
            await sleep(passSeconds)
        }
        return nil
    }
}
