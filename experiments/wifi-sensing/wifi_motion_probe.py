#!/usr/bin/env python3
"""Crude Wi-Fi motion probe using the signal strength (RSSI) of your own link.

Two modes:
  --info   Report the Wi-Fi hardware and whether it can give real CSI.
  default  Sample RSSI ~10x/s while pinging the router, calibrate on a quiet
           room, then flag MOTION when the signal's short-term spread rises.

macOS (via CoreWLAN, needs `swift` from Xcode / Command Line Tools) and Linux
(via /proc/net/wireless). Standard library only. Experiment, not app code.
"""
from __future__ import annotations

import argparse
import collections
import csv
import platform
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


# ---------- hardware info ----------

def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def info() -> None:
    system = platform.system()
    print(f"OS: {system} {platform.release()} ({platform.machine()})")
    if system == "Darwin":
        out = run(["system_profiler", "SPAirPortDataType"])
        for key in ("Card Type", "Firmware Version", "Supported PHY Modes", "PHY Mode", "Channel", "Signal / Noise"):
            m = re.search(rf"^\s*{re.escape(key)}:\s*(.+)$", out, re.M)
            if m:
                print(f"{key}: {m.group(1).strip()}")
        print("\nCSI: not available. Apple's Wi-Fi chips expose no channel state info;"
              " only RSSI-based sensing (this script) is possible on a Mac.")
        return
    if system == "Linux":
        model = Path("/proc/device-tree/model")
        pi = model.exists() and "Raspberry Pi" in model.read_text(errors="ignore")
        cards = run(["lspci", "-nn"]) + run(["lsusb"])
        wifi = [l for l in cards.splitlines() if re.search(r"network|wireless|wi-?fi|802\.11", l, re.I)]
        print("Wi-Fi devices:\n  " + ("\n  ".join(wifi) if wifi else "(none found via lspci/lsusb)"))
        if pi:
            print(f"Board: {model.read_text(errors='ignore').strip(chr(0))}")
        text = " ".join(wifi)
        if re.search(r"AX200|AX210|AX211|Wi-?Fi 6E?", text, re.I):
            print("\nCSI: likely YES via FeitCSI or PicoScenes (Intel AX200/AX210 family).")
        elif re.search(r"5300", text):
            print("\nCSI: YES via the Linux 802.11n CSI Tool (Intel 5300, legacy).")
        elif re.search(r"AR9[0-9]{3}|Atheros", text, re.I):
            print("\nCSI: possibly via the Atheros CSI Tool (ath9k, 802.11n only).")
        elif pi:
            print("\nCSI: likely YES via nexmon_csi (Pi 3B+/4/5 Broadcom chip), at the cost of the Pi's Wi-Fi.")
        else:
            print("\nCSI: no known CSI tool for this card; RSSI-based sensing only.")
        return
    print("Unsupported OS for --info.")


# ---------- RSSI sources ----------

def mac_source(interval: float):
    if not shutil.which("swift"):
        sys.exit("`swift` not found. Install Xcode Command Line Tools: xcode-select --install")
    return _mac_samples(interval)


def _mac_samples(interval: float):
    print("Starting the Swift RSSI reader (first run compiles, ~10 s)...", file=sys.stderr)
    proc = subprocess.Popen(["swift", str(HERE / "rssi_mac.swift"), str(interval)],
                            stdout=subprocess.PIPE, text=True)
    assert proc.stdout
    for line in proc.stdout:
        parts = line.split()
        if parts and parts[0].lstrip("-").isdigit():
            rssi = int(parts[0])
            if rssi != 0:  # 0 = not associated
                yield float(rssi)


def linux_source(interval: float):
    path = Path("/proc/net/wireless")
    if not path.exists() or not path.read_text().splitlines()[2:]:
        sys.exit("No wireless interface in /proc/net/wireless.")
    return _linux_samples(path, interval)


def _linux_samples(path: Path, interval: float):
    while True:
        for line in path.read_text().splitlines()[2:]:
            fields = line.split()
            if len(fields) >= 4:
                try:
                    yield float(fields[3].rstrip("."))
                except ValueError:
                    pass
                break
        time.sleep(interval)


# ---------- traffic generator ----------

def default_gateway() -> str | None:
    if platform.system() == "Darwin":
        m = re.search(r"gateway:\s*(\S+)", run(["route", "-n", "get", "default"]))
    else:
        m = re.search(r"default via (\S+)", run(["ip", "route", "show", "default"]))
    return m.group(1) if m else None


def start_pinger(gateway: str) -> subprocess.Popen | None:
    try:
        return subprocess.Popen(["ping", "-i", "0.2", gateway],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


# ---------- detector (pure, testable) ----------

class Detector:
    """Moving-window spread of RSSI vs. a threshold learned on a quiet room."""

    def __init__(self, window: int, factor: float = 3.0, floor_db: float = 1.0):
        self.buf: collections.deque[float] = collections.deque(maxlen=window)
        self.factor, self.floor_db = factor, floor_db
        self.calib: list[float] = []
        self.threshold: float | None = None

    def spread(self) -> float:
        return statistics.pstdev(self.buf) if len(self.buf) >= 2 else 0.0

    def add(self, rssi: float) -> float:
        self.buf.append(rssi)
        s = self.spread()
        if self.threshold is None and len(self.buf) == self.buf.maxlen:
            self.calib.append(s)
        return s

    def finish_calibration(self) -> float:
        base = max(self.calib) if self.calib else 0.0
        self.threshold = max(base * self.factor, self.floor_db)
        return self.threshold

    def is_motion(self, s: float) -> bool:
        return self.threshold is not None and s > self.threshold


# ---------- main loop ----------

def probe(args: argparse.Namespace) -> None:
    system = platform.system()
    source = mac_source(args.interval) if system == "Darwin" else linux_source(args.interval) \
        if system == "Linux" else sys.exit("macOS or Linux only.")

    gw = default_gateway()
    pinger = start_pinger(gw) if gw else None
    print(f"Pinging router {gw} every 0.2 s to keep the link busy." if pinger
          else "Could not find/ping the router; RSSI may update slowly.", file=sys.stderr)

    det = Detector(window=max(2, round(args.window / args.interval)), factor=args.factor)
    writer = None
    if args.log:
        fh = open(args.log, "w", newline="")
        writer = csv.writer(fh)
        writer.writerow(["t", "rssi_dbm", "spread_db", "motion"])

    print(f"\nCALIBRATING for {args.calibrate:.0f} s: leave the room / keep still.", file=sys.stderr)
    t0 = time.time()
    last_vals: collections.deque[float] = collections.deque(maxlen=50)
    events = 0
    in_motion = False
    try:
        for rssi in source:
            now = time.time() - t0
            s = det.add(rssi)
            last_vals.append(rssi)
            if det.threshold is None and now >= args.calibrate:
                th = det.finish_calibration()
                distinct = len(set(last_vals))
                print(f"Calibrated. Threshold = {th:.2f} dB spread."
                      f" ({distinct} distinct RSSI values in the last {len(last_vals)} samples"
                      f"{' -- RSSI barely changes; this device may update it too slowly' if distinct < 3 else ''})",
                      file=sys.stderr)
                print("Now walk between this computer and the router.\n", file=sys.stderr)
            motion = det.is_motion(s)
            if motion and not in_motion:
                events += 1
            in_motion = motion
            bar = "#" * min(40, int(s * 8))
            tag = "MOTION" if motion else ("calib " if det.threshold is None else "      ")
            print(f"\r{now:6.1f}s  rssi {rssi:6.1f} dBm  spread {s:4.2f}  {tag} {bar:<40}", end="", flush=True)
            if writer:
                writer.writerow([f"{now:.2f}", rssi, f"{s:.3f}", int(motion)])
            if args.duration and now >= args.duration:
                break
    except KeyboardInterrupt:
        pass
    finally:
        if pinger:
            pinger.terminate()
        print(f"\nDone. Motion episodes detected: {events}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--info", action="store_true", help="report Wi-Fi hardware / CSI capability and exit")
    p.add_argument("--interval", type=float, default=0.1, help="seconds between RSSI samples (default 0.1)")
    p.add_argument("--window", type=float, default=2.0, help="seconds in the moving window (default 2)")
    p.add_argument("--calibrate", type=float, default=20.0, help="quiet-room calibration seconds (default 20)")
    p.add_argument("--factor", type=float, default=3.0, help="threshold = factor x quiet spread (default 3)")
    p.add_argument("--duration", type=float, default=0, help="stop after N seconds (default: until Ctrl-C)")
    p.add_argument("--log", help="write samples to this CSV file")
    args = p.parse_args()
    info() if args.info else probe(args)


if __name__ == "__main__":
    main()
