"""Windows-friendly static checks; DOES NOT compile iOS code (requires Xcode/macOS)."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
files = [ROOT / "RUN30" / name for name in (
    "RUN30App.swift", "Views.swift", "Models.swift", "GPSTracker.swift", "CloudStore.swift", "RouteMap.swift", "Info.plist")]
files += [ROOT / "project.yml", ROOT / ".github/workflows/build-ios.yml"]
missing = [str(f) for f in files if not f.exists()]
assert not missing, f"Missing files: {missing}"

plist = plistlib.loads((ROOT / "RUN30/Info.plist").read_bytes())
assert "location" in plist["UIBackgroundModes"]
assert "NSLocationWhenInUseUsageDescription" in plist
swift = {p.stem: p.read_text(encoding="utf-8") for p in files if p.suffix == ".swift"}
assert "allowsBackgroundLocationUpdates = true" in swift["GPSTracker"]
assert "requestWhenInUseAuthorization" in swift["GPSTracker"]
assert "startUpdatingLocation()" in swift["GPSTracker"]
assert "run30_sync" in swift["CloudStore"]
assert "resolution=merge-duplicates" in swift["CloudStore"]
assert "accessToken" in swift["CloudStore"]
assert "SecItemAdd" in swift["CloudStore"]
assert "record:" in swift["CloudStore"]
assert "gps:" in swift["Models"]
assert "CODE_SIGNING_ALLOWED=NO" in (ROOT / ".github/workflows/build-ios.yml").read_text()
assert "RUN30-unsigned.ipa" in (ROOT / ".github/workflows/build-ios.yml").read_text()

source = swift["Models"].split("static let distances: [[Double]] = [",1)[1].split("    ]",1)[0]
rows = re.findall(r"\[([\d., ]+)\]",source)
assert len(rows)==26, f"Expected 26 plan weeks, got {len(rows)}"
plan = [[float(x) for x in row.split(",")] for row in rows]
assert all(len(week)==4 for week in plan)
assert plan[0]==[2,2,2,3]
assert plan[-1]==[4,3,2,30]
print("OK: 26 weeks x 4 workouts; native GPS background Info.plist; auth/sync; unsigned IPA CI.")
print("NOTE: SwiftUI type checking and final .ipa build require macOS/Xcode in GitHub Actions.")
