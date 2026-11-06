"""Look for the rigid body where it is about to be, instead of across the whole frame.

Finding tags across a full 1280x800 frame is most of the detect stage; the refinement
after it costs little. So each camera searches one window around the whole body: the
body's tags projected through the last pose, joined with the corners that camera last
saw, moved on by the window's last step. Then rapidtag's multistage refiner sharpens
the corners and re-finds a tag the detector missed from where its track predicts it.

One window for the body rather than one per tag: a window also covers a tag that is
only now turning into view, and it is a single search.

The corners the camera last saw are in the window as well as the projection, so a
wrong camera mapping (docs/camera_stream_swap.md), which puts the other camera's
projection ~150 mm out, costs a larger window and not the tags.

A camera that finds nothing is searched in full every REFRESH_FRAMES; if neither camera
has anything to follow, both are searched in full every frame, as without this module.
A healthy camera also gets a full search every REFRESH_FRAMES, so a tag that is not
where the calibration says still gets found. The two cameras take theirs half a period
apart, so a frame never pays for both.
"""
from __future__ import annotations

from typing import Optional

import cv2
import numpy as np
import rapidtag

MARGIN_PX = 24            # beyond the body's outline, before motion
MOTION_MARGIN = 2.0       # extra margin, in lengths of the window's last step
REFRESH_FRAMES = 60

Window = tuple[int, int, int, int]  # x0, y0, x1, y1


class BodySearch:
    def __init__(self, dictionary: str, params, frame_size: tuple[int, int], cameras):
        """`cameras`: ((K0, D0), (K1, D1)) in stream order."""
        self.dictionary = dictionary
        self.params = params
        self.width, self.height = frame_size
        self.cameras = cameras
        self.refiners = [rapidtag.MultiStageRefiner(dictionary, parallel=True) for _ in range(2)]
        self.reset()

    def reset(self) -> None:
        """Forget the body and its tracks: the frames are no longer consecutive."""
        self.sample = 0
        self.windows: list[Optional[Window]] = [None, None]
        self._centre = [None, None]
        self._step = [np.zeros(2), np.zeros(2)]
        self.area_share = 0.0     # of the frame searched, since the last report
        self.full_searches = 0
        self.frames = 0
        for refiner in self.refiners:
            refiner.reset()

    def find(self, frames, full: bool = False):
        """Detect in each camera's window. Returns [(corners, ids, origin)] per camera,
        corners in window pixels, and keeps the crops for refine()."""
        self.sample += 1
        self.frames += 1
        either = any(w is not None for w in self.windows)
        crops, origins, searched = [], [], []
        for cam, frame in enumerate(frames):
            due = (self.sample + cam * REFRESH_FRAMES // 2) % REFRESH_FRAMES == 0
            window = self.windows[cam]
            if full or due or not either:
                window = (0, 0, self.width, self.height)
                self.full_searches += 1
            elif window is None:
                continue  # the other camera has the body, and this one's rescue is not due
            x0, y0, x1, y1 = window
            self.area_share += (x1 - x0) * (y1 - y0) / (2 * self.width * self.height)
            crops.append(frame if (x1 - x0, y1 - y0) == (self.width, self.height)
                         else np.ascontiguousarray(frame[y0:y1, x0:x1]))
            origins.append((x0, y0))
            searched.append(cam)
        found = rapidtag.detect_markers_batch(crops, self.dictionary, self.params) if crops else []
        results = [([], [], (0, 0), None) for _ in frames]
        for cam, crop, origin, (corners, ids) in zip(searched, crops, origins, found):
            results[cam] = (corners, ids, origin, crop)
        return results

    def refine(self, results):
        """Multistage refinement. Returns [(corners in frame pixels, ids)] per camera."""
        out = []
        for cam, (corners, ids, origin, crop) in enumerate(results):
            if crop is None:
                out.append(([], []))
                continue
            refined, kept, _how = self.refiners[cam].refine(
                crop, corners if len(ids) else None, ids if len(ids) else None,
                self.sample, (float(origin[0]), float(origin[1])))
            shift = np.array(origin, dtype=np.float64)
            out.append(([quad + shift for quad in refined], list(kept)))
        return out

    def follow(self, found, rig=None, rvec=None, tvec=None, stereo=None) -> None:
        """Set the next frame's windows from this frame's tags and pose (in cam0's
        frame, None when there is none). `stereo` is (R, T) from cam0 to cam1."""
        projected = self._project(rig, rvec, tvec, stereo)
        for cam, (corners, _ids) in enumerate(found):
            parts = list(corners)
            if projected[cam] is not None:
                parts.append(projected[cam])
            self.windows[cam] = self._window(cam, parts)

    def _project(self, rig, rvec, tvec, stereo):
        if rig is None or rvec is None or tvec is None:
            return [None, None]
        points = np.concatenate(list(rig.corners_reference.values())).reshape(-1, 1, 3)
        rvec = np.asarray(rvec, dtype=np.float64).reshape(3, 1)
        tvec = np.asarray(tvec, dtype=np.float64).reshape(3, 1)
        poses = [(rvec, tvec)]
        if stereo is None:
            poses.append(None)
        else:
            poses.append(cv2.composeRT(rvec, tvec, cv2.Rodrigues(stereo[0])[0],
                                       np.asarray(stereo[1], dtype=np.float64).reshape(3, 1))[:2])
        out = []
        for pose, (K, D) in zip(poses, self.cameras):
            if pose is None:
                out.append(None)
                continue
            # Behind the camera a fisheye projection still lands in the image.
            R = cv2.Rodrigues(pose[0])[0]
            depth = (points.reshape(-1, 3) @ R[2]) + pose[1][2, 0]
            if not np.all(depth > 0):
                out.append(None)
                continue
            image, _ = cv2.fisheye.projectPoints(points, pose[0], pose[1], K, D)
            out.append(image.reshape(-1, 2))
        return out

    def _window(self, cam: int, parts) -> Optional[Window]:
        if not parts:
            self._centre[cam] = None
            self._step[cam] = np.zeros(2)
            return None
        points = np.concatenate([np.asarray(p).reshape(-1, 2) for p in parts])
        low, high = points.min(axis=0), points.max(axis=0)
        centre = (low + high) / 2
        if self._centre[cam] is not None:
            self._step[cam] = centre - self._centre[cam]
        self._centre[cam] = centre
        step = self._step[cam]
        margin = MARGIN_PX + MOTION_MARGIN * float(np.abs(step).max())
        low, high = low + step - margin, high + step + margin
        x0, y0 = max(0, int(low[0])), max(0, int(low[1]))
        x1, y1 = min(self.width, int(high[0]) + 1), min(self.height, int(high[1]) + 1)
        if x1 - x0 < 8 or y1 - y0 < 8:  # the body has left this camera's image
            self._centre[cam] = None
            self._step[cam] = np.zeros(2)
            return None
        return x0, y0, x1, y1

    def report(self) -> str:
        share = self.area_share / max(self.frames, 1) * 100
        text = f"searched {share:.0f}% of the frame, {self.full_searches} full searches"
        self.area_share, self.full_searches, self.frames = 0.0, 0, 0
        return text
