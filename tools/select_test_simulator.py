#!/usr/bin/env python3
"""Select/create the iPhone 14 simulator profile; never silently test a larger UI."""
import json
import subprocess

DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-14"


def run_command(arguments):
    return subprocess.check_output(arguments, text=True).strip()


def select_iphone14(run=run_command):
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
    for values in devices.values():
        for device in values:
            if device.get("isAvailable", True) and (
                device.get("deviceTypeIdentifier") == DEVICE_TYPE
                or device.get("name") in ("iPhone 14", "RouteLocation iPhone 14")
            ):
                return device["udid"]
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
    ios = [value for value in runtimes if value.get("isAvailable", False) and ".iOS-" in value.get("identifier", "")]
    if not ios:
        raise RuntimeError("No available iOS simulator runtime for the required iPhone 14 profile")
    runtime = max(ios, key=lambda value: tuple(int(part) for part in value["version"].split(".")))
    return run(["xcrun", "simctl", "create", "RouteLocation iPhone 14", DEVICE_TYPE, runtime["identifier"]])


if __name__ == "__main__":
    print(select_iphone14())
