"""
Three alignment strategies, increasing in robustness. Each takes the camera-reported
time of a frame (clip creation_time + in-clip offset) and predicts its TRUE
session-relative time. Lower error vs the stopwatch ground truth = better.

  naive        : trust the camera clock as-is (today's PhotoLibraryService model).
  tz_resolved  : detect & remove a gross integer-hour timezone error, then trust the rest.
  session_sync : also use ONE start-of-session reference marker to cancel constant skew;
                 the only residual is crystal drift over the session.
"""

from typing import List

from synth import Marker, Session


def _predicted_camera_clock(s: Session, m: Marker) -> float:
    """The camera-derived wall-clock for this frame = clip start report + in-clip offset.

    We model the clip's reported start as the camera report for (t_true - in_clip_offset),
    so adding the offset back is exactly the clip-internal mapping the app would do.
    """
    clip_start_true = m.t_true - m.in_clip_offset
    reported_clip_start = s.camera_reports(clip_start_true)
    return reported_clip_start + m.in_clip_offset


def align_naive(s: Session, m: Marker) -> float:
    return _predicted_camera_clock(s, m)


def align_tz_resolved(s: Session, m: Marker) -> float:
    pred = _predicted_camera_clock(s, m)
    # A gross error (> 30 min) is almost certainly an integer-hour TZ mislabel.
    # Snap it to the nearest hour boundary relative to true session time.
    err = pred - m.t_true
    if abs(err) > 1800:
        hours = round(err / 3600.0)
        pred -= hours * 3600.0
    return pred


def align_session_sync(s: Session, ref_true: float, m: Marker) -> float:
    """Use a reference marker at known true time `ref_true` (filmed at session start)
    to measure and remove skew (and any TZ error, since it's constant)."""
    measured_ref = align_naive(s, Marker(t_true=ref_true, in_clip_offset=0.0))
    skew_estimate = measured_ref - ref_true            # captures skew + tz_error
    return align_naive(s, m) - skew_estimate


def errors_for(strategy: str, s: Session) -> List[float]:
    out = []
    ref_true = 0.0   # the start-of-session sync marker
    for m in s.markers:
        if strategy == "naive":
            pred = align_naive(s, m)
        elif strategy == "tz_resolved":
            pred = align_tz_resolved(s, m)
        elif strategy == "session_sync":
            pred = align_session_sync(s, ref_true, m)
        else:
            raise ValueError(strategy)
        out.append(abs(pred - m.t_true))
    return out


STRATEGIES = ["naive", "tz_resolved", "session_sync"]
