# Wi-Fi motion probe (experiment)

A quick test of whether your own home Wi-Fi can sense movement, using the
signal strength (RSSI) of your computer's existing connection. Not part of the
Snappet app. Background: `reports/WiFi sensing home security.md`.

Works on macOS (needs `swift`: `xcode-select --install`) and Linux. Standard
library Python 3 only.

```sh
cd experiments/wifi-sensing
python3 wifi_motion_probe.py --info                 # what Wi-Fi hardware you have; can it do CSI?
python3 wifi_motion_probe.py --log run1.csv         # calibrate 20 s in a still room, then walk around
```

How to test:
1. Put the computer a few metres from the router, with open floor between them.
2. Start the probe and stay out of the room (or completely still) for the
   20-second calibration.
3. Walk back and forth across the line between computer and router, then
   stand still, then walk far away from that line. Note the times.
4. Ctrl-C. Compare the `MOTION` periods (or the CSV) with what you did.

Expect: walking through the direct path usually shows; motion elsewhere in the
room often doesn't. That's the limit of single-link RSSI. If calibration
reports that RSSI "barely changes", the OS is updating it too slowly for this
to work on that machine.
