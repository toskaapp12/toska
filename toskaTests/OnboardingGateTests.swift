// ONB-1 (build 98): existing accounts must skip onboarding entirely.
//
// Unit tests for ContentView.shouldShowOnboarding — the pure decision behind
// whether a RETURNING sign-in shows onboarding. New accounts onboard via the
// `.showOnboarding` posted on the creation paths, NOT this check.
//
// ⚠️ WIRING (one-time, do in build 98): this file needs a Unit Testing Bundle
// target with `@testable import toska`. Xcode → File → New → Target → Unit
// Testing Bundle (name e.g. "toskaUnitTests"), add this file to it. The repo
// previously had only a UI-test target (toskaUITests), which is black-box and
// can't see app internals, so a unit target is required. The logic is also
// mirror-verified in CI-independent form; this is the in-project home for it.

import XCTest
@testable import toska

final class OnboardingGateTests: XCTestCase {
    typealias V = ContentView

    func testExistingAccountOnNewDevice_serverFlagTrue_doesNotOnboard() {
        // The reported bug scenario: an existing, onboarded account signs in on a
        // fresh device. The server doc says hasCompletedOnboarding == true.
        XCTAssertFalse(V.shouldShowOnboarding(flag: true, fromCache: false, confirmedAdult: true))
    }

    func testMissingFlag_serverRead_doesNotOnboard() {
        // A legacy/established account whose doc lacks the field must NOT be
        // treated as new (the old `?? false` default was the bug).
        XCTAssertFalse(V.shouldShowOnboarding(flag: nil, fromCache: false, confirmedAdult: true))
    }

    func testCachedFalse_doesNotOnboard() {
        // Account-switch false-negative: a stale/empty CACHED read must never
        // trigger onboarding even if it reads the flag as false.
        XCTAssertFalse(V.shouldShowOnboarding(flag: false, fromCache: true, confirmedAdult: false))
    }

    func testAttestedAccount_doesNotOnboard() {
        // confirmedAdult == true means the account already passed creation/onboarding.
        XCTAssertFalse(V.shouldShowOnboarding(flag: false, fromCache: false, confirmedAdult: true))
    }

    func testGenuinelyNewAccount_onboards() {
        // Server-confirmed explicit false, not yet adult-attested → onboard.
        XCTAssertTrue(V.shouldShowOnboarding(flag: false, fromCache: false, confirmedAdult: false))
    }
}
