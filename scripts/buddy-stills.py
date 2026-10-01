#!/usr/bin/env python3
"""Turn BuddyStillRenderTests' attachments into the widget's asset catalog (progression P4).

Usage: scripts/buddy-stills.py <path.xcresult>
Needs Pillow. Crops each render to a centred square around the buddy, downsizes to 360 px and writes
ios/App/SnappetWidgets/BuddyStills.xcassets/<name>.imageset/.
"""
import json, os, shutil, subprocess, sys, tempfile
from PIL import Image

result = sys.argv[1]
root = os.path.join(os.path.dirname(__file__), "..", "ios", "App", "SnappetWidgets", "BuddyStills.xcassets")
out = tempfile.mkdtemp()
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", out],
               check=True, capture_output=True)
os.makedirs(root, exist_ok=True)
with open(os.path.join(root, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
count = 0
for test in json.load(open(os.path.join(out, "manifest.json"))):
    for a in test["attachments"]:
        name = a["suggestedHumanReadableName"].split("_")[0]
        if not name.startswith("buddy-"):
            continue
        im = Image.open(os.path.join(out, a["exportedFileName"])).convert("RGB")
        w, h = im.size
        # A centred square a bit inside the render: clear of the panel's rounded corners, and the
        # buddy fills more of the widget.
        side = int(min(w, h) * 0.84)
        top = (h - side) // 2
        im = im.crop(((w - side) // 2, top, (w - side) // 2 + side, top + side)).resize((360, 360), Image.LANCZOS)
        d = os.path.join(root, name + ".imageset")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        im.save(os.path.join(d, name + ".png"), optimize=True)
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump({"images": [{"idiom": "universal", "filename": name + ".png"}],
                       "info": {"author": "xcode", "version": 1}}, f, indent=2)
        count += 1
print(f"wrote {count} stills to {os.path.normpath(root)}")
