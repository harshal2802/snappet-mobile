"""
Error model for media <-> HR time-sync (Phase-0b spike).

We do NOT have a device here, so we *model* the error budget that real metadata
exhibits and let the strategies (strategies.py) try to remove it. Everything is
seeded so runs are reproducible. The model is deliberately conservative and its
parameters are the thing a real-data re-run must replace (see RESULTS.md).

Ground truth: the watch HR series sits on the TRUE wall clock (authoritative, #60 §3).
The camera clock is offset from true time by:

    capturedAt(t_true) = t_true + skew + drift_rate * elapsed + tz_error

  - skew        : constant offset (camera clock set a few seconds/minutes off).
  - drift_rate  : seconds of error gained per second of elapsed time (crystal drift).
  - tz_error    : a gross integer-hour error from a timezone/metadata mislabel
                  (QuickTime UTC read as local, EXIF with no TZ, Android DATE_TAKEN).

A "marker" is a frame whose TRUE wall-clock time we know (a visible stopwatch / clap).
Alignment maps the camera-reported time of a marker back onto the HR timeline; the
error is |predicted_true - actual_true|.
"""

from dataclasses import dataclass, field
from typing import List


# Realistic-ish ranges (SECONDS unless noted). These are GUESSES to be replaced by
# real measurement — that is the whole point of the re-run plan.
SKEW_RANGE = (-45.0, 45.0)        # phones/cameras are often tens of seconds off
DRIFT_PPM_RANGE = (-50.0, 50.0)   # parts-per-million crystal drift (~50ppm = 0.18s over 1h)
TZ_ERROR_CHOICES = [0, 0, 0, 3600, -3600, 19800, -28800]  # 0 common; else gross hour offsets


@dataclass
class Marker:
    t_true: float          # true seconds from session start
    in_clip_offset: float  # seconds into the clip this frame sits at (clip-internal mapping)


@dataclass
class Session:
    duration: float                 # seconds
    skew: float
    drift_rate: float               # s per s (dimensionless)
    tz_error: float                 # seconds (gross)
    markers: List[Marker] = field(default_factory=list)

    def camera_reports(self, t_true: float) -> float:
        """What the camera metadata would report for a frame at true time t_true."""
        return t_true + self.skew + self.drift_rate * t_true + self.tz_error


def generate_session(rng, duration: float = 3600.0, n_markers: int = 8,
                     allow_tz_error: bool = True) -> Session:
    skew = rng.uniform(*SKEW_RANGE)
    drift_rate = rng.uniform(*DRIFT_PPM_RANGE) / 1_000_000.0
    tz_error = rng.choice(TZ_ERROR_CHOICES) if allow_tz_error else 0.0
    s = Session(duration=duration, skew=skew, drift_rate=drift_rate, tz_error=tz_error)
    # Markers spread across the session; each sits at a random offset inside a
    # multi-minute clip (to exercise clip-internal mapping).
    for i in range(n_markers):
        t_true = duration * (i + 0.5) / n_markers
        in_clip = rng.uniform(0, 240)   # up to 4 min into a clip
        s.markers.append(Marker(t_true=t_true, in_clip_offset=in_clip))
    return s
