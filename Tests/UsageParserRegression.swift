import Foundation

@main
enum UsageParserRegression {
    static func main() {
        testDualWindows()
        testWeeklyWindowInPrimarySlot()
        testReversedWindowSlots()
        testLegacyWindowPositions()
        testGenericRemainingDoesNotBecomeWeeklyQuota()
        print("UsageParser regression tests passed")
    }

    private static func testDualWindows() {
        let snapshot = UsageParser.parse(#"""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_after_seconds": 3600,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 10,
              "reset_after_seconds": 86400,
              "limit_window_seconds": 604800
            }
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == 58, "dual-window 5h remaining")
        expect(snapshot.weeklyRemainingPercent == 90, "dual-window Week remaining")
    }

    private static func testWeeklyWindowInPrimarySlot() {
        let snapshot = UsageParser.parse(#"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 39,
              "reset_after_seconds": 474388,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == nil, "removed 5h window stays absent")
        expect(snapshot.weeklyRemainingPercent == 61, "primary-slot Week remaining")
        expect(snapshot.primaryResetSeconds == nil, "removed 5h reset stays absent")
        expect(snapshot.weeklyResetSeconds == 474388, "primary-slot Week reset")
    }

    private static func testReversedWindowSlots() {
        let snapshot = UsageParser.parse(#"""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 25,
              "reset_after_seconds": 500000,
              "limit_window_seconds": 604800
            },
            "secondary_window": {
              "used_percent": 40,
              "reset_after_seconds": 9000,
              "limit_window_seconds": 18000
            }
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == 60, "duration identifies reversed 5h window")
        expect(snapshot.weeklyRemainingPercent == 75, "duration identifies reversed Week window")
    }

    private static func testLegacyWindowPositions() {
        let snapshot = UsageParser.parse(#"""
        {
          "rate_limit": {
            "primary_window": {"used_percent": 20, "reset_after_seconds": 1000},
            "secondary_window": {"used_percent": 30, "reset_after_seconds": 2000}
          }
        }
        """#)

        expect(snapshot.primaryRemainingPercent == 80, "legacy primary slot remains 5h")
        expect(snapshot.weeklyRemainingPercent == 70, "legacy secondary slot remains Week")
    }

    private static func testGenericRemainingDoesNotBecomeWeeklyQuota() {
        let snapshot = UsageParser.parse(#"{"remaining": 12, "limit": 20}"#)
        expect(snapshot.primaryRemainingPercent == 60, "generic remaining is normalized for primary")
        expect(snapshot.weeklyRemainingPercent == nil, "generic remaining is not duplicated as Week")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }
}
