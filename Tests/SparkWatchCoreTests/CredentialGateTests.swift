import Foundation
import Testing

@testable import SparkWatchCore

/// The 2026-10-16 incident, as tests.
///
/// Both boxes went dark for hours while the app burned ~200 % CPU. The wait for a
/// sign-in exited on "token != nil" while the guard that sent it there required an
/// *unexpired* token, so a merely expired one made every pass fall straight
/// through with no suspension point — and because that loop never yielded, its
/// actor starved the SSH channel, which needs no credential at all. "No data"
/// therefore looked exactly like a network fault.
@Suite("凭据闸门（过期 token 不得被当成进度）")
struct CredentialGateTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func onlyPresentAndUnexpiredCounts() {
        #expect(CredentialGate.isUsable(token: "t", expiry: now.addingTimeInterval(60), now: now))
        // The incident itself: present, but expired.
        #expect(!CredentialGate.isUsable(token: "t", expiry: now.addingTimeInterval(-1), now: now))
        // Expiring exactly now is over.
        #expect(!CredentialGate.isUsable(token: "t", expiry: now, now: now))
        // An unprovable expiry is not usable: guessing "probably fine" is how a
        // stale token reached the request path in the first place.
        #expect(!CredentialGate.isUsable(token: "t", expiry: nil, now: now))
        #expect(!CredentialGate.isUsable(token: nil, expiry: now.addingTimeInterval(60), now: now))
        #expect(!CredentialGate.isUsable(token: "", expiry: now.addingTimeInterval(60), now: now))
    }

    /// The asymmetry itself, as a property: the question that starts the wait and
    /// the question that ends it must be the same one. This is the assertion the
    /// old code would have failed, and it is the reason both sides now call
    /// `CredentialGate` instead of spelling the test out twice.
    @Test func theWaitAsksExactlyTheGateQuestion() {
        let states: [CredentialState] = [
            .none,
            CredentialState(token: "t", expiry: nil),
            CredentialState(token: "t", expiry: now.addingTimeInterval(-3600)),
            CredentialState(token: "t", expiry: now),
            CredentialState(token: "t", expiry: now.addingTimeInterval(1)),
            CredentialState(token: "", expiry: now.addingTimeInterval(60)),
        ]
        for state in states {
            #expect(
                CredentialWait.passIsDone(state, now: now)
                    == CredentialGate.isUsable(state, now: now)
            )
        }
        let expired = CredentialState(token: "t", expiry: now.addingTimeInterval(-3600))
        // The old exit test looked only at this, and it is true for a token that
        // cannot authenticate.
        #expect(expired.token != nil)
        #expect(!CredentialWait.passIsDone(expired, now: now))
    }

    /// Every pass must suspend. Counted rather than asserted in prose, because the
    /// bug was precisely a pass that did not.
    @Test func everyPassYieldsAndTheWaitEndsWithTheRuntime() async {
        let passCount = Counter()
        let sleeps = SleepLog()
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let outcome = await CredentialWait.until(
            reading: { CredentialState(token: "expired", expiry: clock.addingTimeInterval(-1)) },
            running: { await passCount.bump() <= 3 },
            sleep: { await sleeps.record($0) },
            now: { clock }
        )
        // No usable token ever appeared, so the wait ended because the runtime did.
        #expect(outcome == nil)
        // The stop condition is read before each pass, so it is asked once more
        // than the number of passes that ran.
        let asked = await passCount.value
        let recorded = await sleeps.value
        #expect(asked == 4)
        #expect(recorded.count == 3)
        #expect(recorded.allSatisfy { $0 == CredentialWait.passSeconds })
        #expect(CredentialWait.passSeconds > 0)
    }

    @Test func aUsableTokenEndsTheWaitWithoutSleeping() async {
        let sleeps = SleepLog()
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let usable = CredentialState(token: "good", expiry: clock.addingTimeInterval(3600))
        let outcome = await CredentialWait.until(
            reading: { usable },
            running: { true },
            sleep: { await sleeps.record($0) },
            now: { clock }
        )
        #expect(outcome == usable)
        #expect(await sleeps.value.isEmpty)
    }

    /// A run that is stopped while waiting must come back promptly instead of
    /// holding the task (and, in the app, the actor) for another pass.
    @Test func aStoppedRuntimeDoesNotWaitForAnotherPass() async {
        let passCount = Counter()
        let sleeps = SleepLog()
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let outcome = await CredentialWait.until(
            reading: { CredentialState(token: "expired", expiry: clock.addingTimeInterval(-1)) },
            running: { await passCount.bump() <= 1 },
            sleep: { await sleeps.record($0) },
            now: { clock }
        )
        #expect(outcome == nil)
        #expect(await passCount.value == 2)
        #expect(await sleeps.value.count == 1)
    }
}

/// Hooks the wait calls, so a test can observe that it yielded instead of
/// spinning. Actors, because the wait's hooks are `@Sendable`.
private actor Counter {
    private(set) var value = 0

    func bump() -> Int {
        value += 1
        return value
    }
}

private actor SleepLog {
    private(set) var value: [Double] = []

    func record(_ seconds: Double) {
        value.append(seconds)
    }
}
