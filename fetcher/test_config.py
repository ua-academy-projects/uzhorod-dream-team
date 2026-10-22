import unittest

import config


class ParseModeTests(unittest.TestCase):
    def test_known_modes(self):
        for mode in ("rabbitmq", "postgres"):
            self.assertEqual(config.parse_mode({"APP_MODE": mode}), mode)

    def test_other_values_are_errors(self):
        for value in ("", "RabbitMQ", "postgresql", "redis", " postgres"):
            with self.assertRaises(config.ConfigError) as caught:
                config.parse_mode({"APP_MODE": value})
            self.assertIn("APP_MODE", str(caught.exception))

    def test_missing_mode_is_error(self):
        with self.assertRaises(config.ConfigError):
            config.parse_mode({})


class PositiveNumberTests(unittest.TestCase):
    def test_positive_int(self):
        self.assertEqual(config.positive_int({"N": "5"}, "N"), 5)

    def test_wrong_ints(self):
        for value in ("", "0", "-5", "5s", "2.5", "five"):
            with self.assertRaises(config.ConfigError) as caught:
                config.positive_int({"N": value}, "N")
            self.assertIn("N", str(caught.exception))

    def test_positive_float(self):
        self.assertEqual(config.positive_float({"T": "2.5"}, "T"), 2.5)

    def test_wrong_floats(self):
        for value in ("", "0", "-1", "ten", "nan"):
            with self.assertRaises(config.ConfigError):
                config.positive_float({"T": value}, "T")


class LeaseTests(unittest.TestCase):
    def test_lease_longer_than_four_timeouts_plus_margin(self):
        # Timeout 10 s: one request may take up to 40 s, plus 10 s for the database.
        self.assertEqual(config.min_lease_seconds(10), 50)
        config.check_lease(60, 10)  # the value from provision/fetcher.sh
        config.check_lease(50, 10)

    def test_too_short_lease_is_error(self):
        for lease in (10, 11, 40, 49):
            with self.assertRaises(config.ConfigError) as caught:
                config.check_lease(lease, 10)
            self.assertIn("QUEUE_LEASE_SECONDS", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
