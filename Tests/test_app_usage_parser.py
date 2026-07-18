import unittest

from app import UsageParser


class UsageParserTests(unittest.TestCase):
    def test_weekly_window_in_primary_slot(self):
        snapshot = UsageParser.parse(
            """
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
            """
        )

        self.assertIsNone(snapshot.primary_remaining_percent)
        self.assertEqual(snapshot.weekly_remaining_percent, 61)
        self.assertIsNone(snapshot.primary_reset_seconds)
        self.assertEqual(snapshot.weekly_reset_seconds, 474388)

    def test_window_duration_wins_over_slot_order(self):
        snapshot = UsageParser.parse(
            """
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
            """
        )

        self.assertEqual(snapshot.primary_remaining_percent, 60)
        self.assertEqual(snapshot.weekly_remaining_percent, 75)

    def test_generic_remaining_is_not_duplicated_as_weekly(self):
        snapshot = UsageParser.parse('{"remaining": 12, "limit": 20}')
        self.assertEqual(snapshot.primary_remaining_percent, 60)
        self.assertIsNone(snapshot.weekly_remaining_percent)


if __name__ == "__main__":
    unittest.main()
