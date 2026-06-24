"""Per-marker corner deadband stabilizer.

When a marker's detected corners barely move between frames, the marker is
physically still and any change in the recovered pose is PnP jitter from
sub-pixel corner noise. This holds the previous pose in that case, which both
removes the static jitter and skips the (relatively expensive) solve entirely.

Gating is done on *pixel* displacement of the corners rather than on the 3D
output: the corner->pose map is nonlinear (a fraction of a pixel on a distant
marker becomes large depth jitter), so a pixel threshold is in stable, tunable
units across all depths.
"""

import numpy as np


class CornerStabilizer:
    def __init__(self, threshold_px: float = 0.5):
        # Max per-corner displacement (px) below which a marker counts as static.
        self.threshold_px = threshold_px
        # (marker_id, view_label) -> previous (4, 2) corner array
        self._prev_corners: dict[tuple, np.ndarray] = {}
        # marker_id -> last accepted (rvec, tvec)
        self._prev_pose: dict[int, tuple] = {}

    def _is_static(self, key: tuple, corners: np.ndarray) -> bool:
        """Update stored corners for `key` and report whether they barely moved."""
        prev = self._prev_corners.get(key)
        self._prev_corners[key] = corners.copy()
        if prev is None:
            return False
        max_disp = np.linalg.norm(corners - prev, axis=1).max()
        return max_disp < self.threshold_px

    def stabilize(self, mid: int, corner_sets: dict, compute):
        """Return a pose for marker `mid`, reusing the previous one when static.

        corner_sets: {view_label: (4, 2) corner array} for every view this
            marker is solved from (e.g. {"c0": ...} or {"c0": ..., "c1": ...}).
            The pose is frozen only when *all* supplied views are static.
        compute: zero-arg callable returning (rvec, tvec); invoked only when a
            fresh solve is needed. May return (None, None) on failure.
        """
        # List-comp (not a generator) so every view's stored corners get updated
        # even when an earlier view already proved non-static.
        statics = [self._is_static((mid, lbl), c) for lbl, c in corner_sets.items()]

        if all(statics) and mid in self._prev_pose:
            return self._prev_pose[mid]

        rvec, tvec = compute()
        if rvec is not None:
            self._prev_pose[mid] = (rvec, tvec)
        return rvec, tvec
