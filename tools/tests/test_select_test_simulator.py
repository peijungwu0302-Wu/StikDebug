import json
import unittest
from tools.select_test_simulator import select_iphone14


class SimulatorSelectionTests(unittest.TestCase):
    def test_reuses_iphone14_not_larger_first_device(self):
        devices = {"devices": {"ios": [
            {"name": "iPhone 17 Pro", "udid": "large"},
            {"name": "iPhone 14", "udid": "required"},
        ]}}
        calls = []

        def run(arguments):
            calls.append(arguments)
            return json.dumps(devices)

        self.assertEqual(select_iphone14(run), "required")
        self.assertEqual(len(calls), 1)

    def test_creates_required_profile_with_available_ios_runtime(self):
        calls = []

        def run(arguments):
            calls.append(arguments)
            if "devices" in arguments:
                return json.dumps({"devices": {"ios": [{"name": "iPhone 17", "udid": "wrong"}]}})
            if "runtimes" in arguments:
                return json.dumps({"runtimes": [
                    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "isAvailable": True},
                    {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "version": "26.1", "isAvailable": False},
                ]})
            return "created"

        self.assertEqual(select_iphone14(run), "created")
        self.assertEqual(calls[-1], ["xcrun", "simctl", "create", "RouteLocation iPhone 14",
                                    "com.apple.CoreSimulator.SimDeviceType.iPhone-14",
                                    "com.apple.CoreSimulator.SimRuntime.iOS-26-0"])

    def test_missing_runtime_fails_instead_of_using_wrong_screen_size(self):
        def run(arguments):
            return json.dumps({"devices": {}} if "devices" in arguments else {"runtimes": []})
        with self.assertRaisesRegex(RuntimeError, "No available iOS"):
            select_iphone14(run)
