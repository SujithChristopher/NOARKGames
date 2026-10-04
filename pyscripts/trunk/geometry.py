"""Torso front-shell point cloud from the stereo pair.

The realtime port of 06_trunk_axis.py's stereo_step: fisheye rectification,
SGBM, the torso mask, then one depth layer of the masked points. It runs at
half sensor resolution: full-resolution SGBM measured 289 ms on the big cores
against 21 ms at half, and the cloud is voxelised to 1 cm afterwards anyway.

Points come out in the *reference* camera's frame (metres, x right, y down,
z forward), which is whichever stream is physically on the left — SGBM needs
the left image first.
"""

import cv2
import numpy as np

SCALE = 0.5
DEPTH_MIN_M, DEPTH_MAX_M = 0.3, 2.0
MASK_ERODE_FRAC = 0.06       # erode the mask by this * sqrt(area): drops the curved flanks
MODE_BIN_M = 0.01            # shell: depth histogram bin
MODE_HALF_M = 0.10           # shell: keep points within this of the histogram peak
CLOUD_VOXEL_M = 0.01
SGBM_BLOCK = 5
BILATERAL = (5, 8.0, 5.0)    # d, sigma colour (disparity px), sigma space


def voxel_downsample(pts, voxel=CLOUD_VOXEL_M, max_pts=2000, rng=None):
    """Mean point per occupied voxel; random-subsample to max_pts if still too many."""
    if len(pts) == 0:
        return pts
    # One int64 per voxel (21 bits an axis) so the grouping is a 1-D unique;
    # np.unique(axis=0) on the 3-column keys was most of this function's time.
    k = np.floor(pts / voxel).astype(np.int64)
    k -= k.min(axis=0)
    key = (k[:, 0] << 42) | (k[:, 1] << 21) | k[:, 2]
    _, inv, cnt = np.unique(key, return_inverse=True, return_counts=True)
    ds = np.column_stack([np.bincount(inv, weights=pts[:, i], minlength=len(cnt))
                          for i in range(3)]) / cnt[:, None]
    if len(ds) > max_pts:
        ds = ds[(rng or np.random.default_rng(0)).choice(len(ds), max_pts, replace=False)]
    return ds


def shell_points(tp):
    """The densest depth layer of the torso points: the front shell, without
    the flanks or whatever sits behind the subject inside the mask."""
    if not len(tp):
        return tp
    z = tp[:, 2]
    edges = np.arange(z.min(), max(z.max() + 2 * MODE_BIN_M, z.min() + 3.5 * MODE_BIN_M),
                      MODE_BIN_M)
    h, _ = np.histogram(z, edges)
    h = np.convolve(h, np.ones(3) / 3, mode="same")
    zp = (edges[:-1] + edges[1:])[int(np.argmax(h))] / 2
    return tp[np.abs(z - zp) <= MODE_HALF_M]


class StereoShell:
    """Rectification + SGBM for one calibrated pair, built once."""

    def __init__(self, K0, D0, K1, D1, R, T, size):
        """K/D per stream, R/T stream0 -> stream1 (metres), size = sensor (W, H)."""
        # Whichever camera is on the left is the reference. p1 = R p0 + T, so
        # stream1 sits at -R^T T in stream0's frame; x > 0 means it is to the right.
        self.swap = float((-R.T @ T.reshape(3, 1))[0, 0]) < 0
        if self.swap:
            K0, D0, K1, D1 = K1, D1, K0, D0
            R, T = R.T, -R.T @ T.reshape(3, 1)
        W, H = size
        self.size = (int(round(W * SCALE)), int(round(H * SCALE)))
        S = np.diag([SCALE, SCALE, 1.0])
        K0s, K1s = S @ K0, S @ K1
        R1, R2, P1, P2, Q = cv2.fisheye.stereoRectify(
            K0s, D0, K1s, D1, self.size, R, T.reshape(3, 1),
            flags=cv2.CALIB_ZERO_DISPARITY, balance=0.0, fov_scale=1.0)
        self.maps0 = cv2.fisheye.initUndistortRectifyMap(K0s, D0, R1, P1, self.size, cv2.CV_16SC2)
        self.maps1 = cv2.fisheye.initUndistortRectifyMap(K1s, D1, R2, P2, self.size, cv2.CV_16SC2)
        self.R1, self.Q = R1, Q
        baseline = float(np.linalg.norm(T))
        d_max = P1[0, 0] * baseline / DEPTH_MIN_M
        self.num_disp = int(np.ceil(d_max / 16.0)) * 16
        self.sgbm = cv2.StereoSGBM_create(
            minDisparity=0, numDisparities=self.num_disp, blockSize=SGBM_BLOCK,
            P1=8 * SGBM_BLOCK ** 2, P2=32 * SGBM_BLOCK ** 2, disp12MaxDiff=1,
            uniquenessRatio=10, speckleWindowSize=100, speckleRange=2,
            mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY)

    def reference(self, raw0, raw1):
        """The (left, right) frames in SGBM order, at full resolution."""
        return (raw1, raw0) if self.swap else (raw0, raw1)

    def shell(self, left_small, right_small, mask_small):
        """Front-shell torso points (N, 3) in the left camera's frame.

        All three images are already at self.size; mask is uint8 0/255 in the
        left image's (unrectified) pixels."""
        rect0 = cv2.remap(left_small, *self.maps0, cv2.INTER_LINEAR)
        rect1 = cv2.remap(right_small, *self.maps1, cv2.INTER_LINEAR)
        mrect = cv2.remap(mask_small, *self.maps0, cv2.INTER_NEAREST)
        area = int(np.count_nonzero(mrect))
        if area == 0:
            return np.zeros((0, 3))
        k = max(3, int(round(np.sqrt(area) * MASK_ERODE_FRAC))) | 1
        mrect = cv2.erode(mrect, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))

        # Match only the torso's box. The left edge reaches back num_disp
        # pixels, since the left image's leftmost columns have no full search
        # range; the margins cover the block and the bilateral window. About a
        # third of the image on a seated patient, and SGBM cost is per pixel.
        ys, xs = np.nonzero(mrect)
        H, W = mrect.shape
        m = SGBM_BLOCK + BILATERAL[0]
        y0, y1 = max(0, ys.min() - m), min(H, ys.max() + 1 + m)
        x0, x1 = max(0, xs.min() - m - self.num_disp), min(W, xs.max() + 1 + m)
        disp_raw = self.sgbm.compute(rect0[y0:y1, x0:x1],
                                     rect1[y0:y1, x0:x1]).astype(np.float32) / 16.0
        # Smooth for the 3D values, but gate validity on the raw disparity so
        # SGBM's own invalid-pixel boundary is not blurred away.
        disp = cv2.bilateralFilter(disp_raw, *BILATERAL)
        v, u = np.nonzero((mrect[y0:y1, x0:x1] > 0) & (disp_raw > 0))
        if not len(u):
            return np.zeros((0, 3))
        d = disp[v, u]
        h = np.column_stack([u + x0, v + y0, d, np.ones_like(d)]).astype(np.float64) @ self.Q.T
        ok = np.abs(h[:, 3]) > 1e-9
        pts = h[ok, :3] / h[ok, 3:4]
        z = pts[:, 2]
        pts = pts[(z > DEPTH_MIN_M) & (z < DEPTH_MAX_M)]
        # rectified -> camera frame (R1 maps camera -> rectified)
        return shell_points(pts) @ self.R1
