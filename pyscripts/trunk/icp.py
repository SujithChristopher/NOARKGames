"""Trunk rotation by rigid registration of the torso front shell to a neutral cloud.

The realtime port of NOARK_backbone/trunkpose/dual_notebooks/07_icp_trunk.py:
trimmed point-to-plane ICP with an annealed match distance, tried from several
seeds, with keyframe odometry as the fallback when the live shell has turned too
far to overlap the neutral view, and a physical-plausibility gate (a seated
trunk never goes past ~45 deg). See that script for why each piece exists — in
short: the shell has a near-mirror basin ~180 deg away that fits as well as the
right one, so a single warm start can lock onto it for good.
"""

import numpy as np
from scipy.spatial import cKDTree
from scipy.spatial.transform import Rotation

ICP_ITERS = 20
ICP_DISTS = (0.06, 0.03, 0.02)   # trimming threshold annealing (m)
ICP_MIN_MATCH = 150
NORMAL_K = 15
DIRECT_RMS_M = 0.030
DIRECT_FRAC = 0.30
ODO_RMS_M = 0.010
ODO_FRAC = 0.50
KEY_ROT_DEG = 15.0
ROT_MAX_DEG = 45.0
ODO_MAX_RUN = 30
SEED_EXIT_RMS_M = 0.012


def rot_deg(R):
    return float(np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1))))


def estimate_normals(pts, k=NORMAL_K):
    """Local-PCA normals, oriented outward from the centroid (a convex-ish shell)."""
    k = min(k, len(pts) - 1)
    if k < 3:
        return np.tile(np.array([0.0, 0.0, -1.0]), (len(pts), 1))
    _, idx = cKDTree(pts).query(pts, k=k)
    neigh = pts[idx]
    centered = neigh - neigh.mean(axis=1, keepdims=True)
    cov = np.einsum("nki,nkj->nij", centered, centered) / k
    _, vecs = np.linalg.eigh(cov)
    normals = vecs[:, :, 0]
    flip = np.einsum("ni,ni->n", normals, pts - pts.mean(axis=0)) < 0
    normals[flip] *= -1
    return normals


def icp(src, dst, tree, normals, R, t):
    """Point-to-plane ICP src -> dst from (R, t). Returns (R, t, rms, n_matched)
    or None when too few points match."""
    rms, matched = np.nan, 0
    for dist in ICP_DISTS:
        for _ in range(ICP_ITERS):
            moved = src @ R.T + t
            d, idx = tree.query(moved, k=1, distance_upper_bound=dist)
            m = d < dist
            matched = int(m.sum())
            if matched < ICP_MIN_MATCH:
                return None
            rp, q, n = src[m] @ R.T, dst[idx[m]], normals[idx[m]]
            resid = np.einsum("ni,ni->n", n, rp + t - q)
            A = np.concatenate([np.cross(rp, n), n], axis=1)
            # 6x6 normal equations rather than lstsq: same answer at this
            # conditioning, and no BLAS thread pool waking on the hand
            # tracker's cores every iteration.
            x = np.linalg.solve(np.einsum("ni,nj->ij", A, A) + 1e-9 * np.eye(6),
                                -np.einsum("ni,n->i", A, resid))
            Rn = Rotation.from_rotvec(x[:3]).as_matrix() @ R
            delta = rot_deg(Rn @ R.T)
            R, t = Rn, t + x[3:]
            rms = float(np.sqrt((d[m] ** 2).mean()))
            if delta < 0.01:
                break
    return R, t, rms, matched


class Neutral:
    """The reference cloud and the anatomical frame defined at neutral.

    Registration runs about the neutral centroid, not the camera origin: the
    shell sits most of a metre from the camera, and a small-angle solve about a
    point that far away mixes rotation with translation and converged to the
    wrong pose in testing. Rotation is the same either way; only t changes."""

    def __init__(self, cloud, lateral_sign=1.0):
        self.centre = cloud.mean(axis=0)
        self.cloud = cloud - self.centre
        self.tree = cKDTree(self.cloud)
        self.normals = estimate_normals(self.cloud)
        self.R_neu = anatomical_frame(cloud, lateral_sign)


def anatomical_frame(cloud, lateral_sign=1.0):
    """Columns (x lateral = patient's left, u up, a anterior) in camera axes.

    Without shoulder landmarks the frame comes from the neutral shell itself:
    anterior is the shell's normal (pointing at the camera, which the patient
    faces), lateral is the camera's x axis made orthogonal to it — the camera
    sees the patient mirrored, so image-right is the patient's left — and up
    completes it. A tilted camera tilts the axes with it; only the split of a
    rotation between flexion/lateral/axial depends on this, not its size."""
    c = cloud - cloud.mean(axis=0)
    _, _, vt = np.linalg.svd(c, full_matrices=False)
    a = vt[2]
    if a @ cloud.mean(axis=0) > 0:          # face the camera
        a = -a
    x = np.array([lateral_sign, 0.0, 0.0])
    x = x - (x @ a) * a
    x /= np.linalg.norm(x)
    u = np.cross(a, x)
    u /= np.linalg.norm(u)
    a = np.cross(x, u)
    return np.column_stack([x, u, a])


def trunk_angles(R_t, R_neu):
    """(flexion, lateral, axial) in degrees, the 06/07 convention:
    flexion + = leaning forward, lateral + = leaning to the patient's left,
    axial + = left shoulder moving forward (turning to the right)."""
    x0, u0, a0 = R_neu[:, 0], R_neu[:, 1], R_neu[:, 2]
    x, u = R_t[:, 0], R_t[:, 1]
    return (float(np.degrees(np.arctan2(u @ a0, u @ u0))),
            float(np.degrees(np.arctan2(u @ x0, u @ u0))),
            float(np.degrees(np.arctan2(x @ a0, x @ x0))))


class Registration:
    """Per-frame registration against one neutral, with the warm-start state."""

    def __init__(self, neutral: Neutral):
        self.neu = neutral
        self.A = (np.eye(3), np.zeros(3))     # current estimate: cur -> neutral
        self.last_good = None                 # (cloud, A)
        self.key = None                       # (tree, cloud, A_k, normals)
        self.odo_run = 0

    def step(self, src):
        """Register one frame's cloud. Returns (R_body, info) where R_body is the
        rotation from neutral to now (None on failure) and info says how."""
        neu = self.neu
        src = src - neu.centre
        seeds = [self.A]
        for cand in ((self.last_good[1] if self.last_good else None),
                     (np.eye(3), np.zeros(3))):
            if cand is not None and not any(
                    np.allclose(cand[0], s[0]) and np.allclose(cand[1], s[1]) for s in seeds):
                seeds.append(cand)
        best, gated = None, False
        for R_s, t_s in seeds:
            res = icp(src, neu.cloud, neu.tree, neu.normals, R_s, t_s)
            if not res or res[2] > DIRECT_RMS_M or res[3] < DIRECT_FRAC * len(src):
                continue
            if rot_deg(res[0]) > ROT_MAX_DEG:
                gated = True
                continue
            if best is None or res[2] < best[2]:
                best = res
            # The extra seeds exist to climb out of a wrong basin; a warm start
            # that converged to a plausible pose has nothing to climb out of.
            if best[2] < SEED_EXIT_RMS_M:
                break
        got, how, rms, frac = None, None, np.nan, np.nan
        if best is not None:
            got, how, rms = (best[0], best[1]), "direct", best[2]
            frac = best[3] / len(src)
            self.key, self.odo_run = None, 0
        elif not gated:
            got, rms, frac = self._odometry(src)
            how = "odometry" if got is not None else None
        if got is None:
            return None, dict(how="gated" if gated else "failed", rms=rms, frac=frac)
        if rot_deg(got[0]) > ROT_MAX_DEG:
            return None, dict(how="gated", rms=rms, frac=frac)
        self.A = got
        self.last_good = (src, got)
        return got[0].T, dict(how=how, rms=rms, frac=frac)

    def _odometry(self, src):
        if self.key is None and self.last_good is not None:
            kc, kA = self.last_good
            self.key = (cKDTree(kc), kc, kA, estimate_normals(kc))
        if self.key is None or self.odo_run >= ODO_MAX_RUN:
            return None, np.nan, np.nan
        ktree, kc, (Rk, tk), kn = self.key
        res = icp(src, kc, ktree, kn, Rk.T @ self.A[0], Rk.T @ (self.A[1] - tk))
        if not res or res[2] > ODO_RMS_M or res[3] < ODO_FRAC * len(src):
            return None, np.nan, np.nan
        got = (Rk @ res[0], Rk @ res[1] + tk)
        self.odo_run += 1
        if rot_deg(res[0]) > KEY_ROT_DEG:
            self.key = (cKDTree(src), src, got, estimate_normals(src))
        return got, res[2], res[3] / len(src)
