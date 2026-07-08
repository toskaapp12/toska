import XCTest

// MARK: - Performance pass (2026-07-07, polish-guide §8.6)
// Headless stand-in for an Instruments session: XCTOSSignpostMetric watches
// UIKit's built-in scroll signposts, so hitch time/ratio during feed scrolling
// is measured without any in-app instrumentation. Run on a booted simulator
// with the staging account already signed in (keychain persists across
// launches — the Walkthrough suite's login leaves the right state).
// Read results from the .xcresult metrics, not stdout.
final class PerfScrollTests: XCTestCase {

    // Cold-ish launch time (process start → first frame). measure() launches
    // the app 5 times; the metric reports the distribution.
    func test01_launchTime() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // Feed scroll hitches: flick the feed up/down repeatedly and let the
    // scroll-deceleration signpost metric report hitch time ratio. The feed
    // is the app's hottest path (serif layout + GIFs + live counters).
    func test02_feedScrollHitches() throws {
        let app = XCUIApplication()
        app.launch()
        let feed = app.otherElements["feedView"].firstMatch
        guard feed.waitForExistence(timeout: 30) else {
            throw XCTSkip("feed not reachable (signed out?) — run WalkthroughUITests first")
        }
        let metric = XCTOSSignpostMetric.scrollDecelerationMetric
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [metric], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            stopMeasuring()
        }
    }
}
