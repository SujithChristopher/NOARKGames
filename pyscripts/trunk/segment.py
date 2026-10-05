"""Torso mask from trunk_seg (YOLOv8n-seg: torso, arm, head) on the Hexagon NPU.

The model is the W8A8 QDQ graph quantized on Qualcomm AI Hub (job j57e32mlp),
cut just before the head's final Concat so boxes, scores and mask coefficients
each keep their own quantization scale. The CPU tail (NMS + masks) mirrors
ultralytics' predict path. Ported from yolo-test/trunk_seg and npu_session.py;
see yolo-test/docs/hexagon-npu.md for why the session settings are what they
are — several of the defaults fail silently.
"""

from pathlib import Path

import cv2
import numpy as np

MODEL_PATH = Path(__file__).parent / "models" / "trunk_seg_w8a8" / "model.onnx"
IMGSZ = 640
TORSO, ARM, HEAD = 0, 1, 2
CONF = 0.25
IOU = 0.7
ARM_EXCLUDE_DILATE_PX = 9   # at full sensor resolution, as in 06_trunk_axis.py


def npu_session(model):
    """ONNX Runtime session with the graph on the HTP. Raises without an NPU."""
    import onnxruntime as ort
    import onnxruntime_qnn as oq

    ort.register_execution_provider_library(oq.EP_NAME, oq.get_library_path())
    devices = [d for d in ort.get_ep_devices() if d.ep_name == oq.EP_NAME]
    if not devices:
        raise RuntimeError("QNN EP registered but no NPU device found")
    so = ort.SessionOptions()
    so.log_severity_level = 3
    # ORT's CPU pool only runs the boundary quantize/dequantize nodes; left at
    # defaults its threads spin-wait and starve the CPU-side tail.
    so.intra_op_num_threads = 1
    so.add_session_config_entry("session.intra_op.allow_spinning", "0")
    so.add_session_config_entry("session.inter_op.allow_spinning", "0")
    # Plugin EPs must be attached per device: providers=[...] silently runs on CPU.
    so.add_provider_for_devices(devices, {
        "backend_path": oq.get_qnn_htp_path(),
        "htp_graph_finalization_optimization_mode": "3",
    })
    sess = ort.InferenceSession(str(model), so)
    if "QNNExecutionProvider" not in sess.get_providers():
        raise RuntimeError(f"trunk_seg is not on the NPU: {sess.get_providers()}")
    return sess


def _decode(boxes, scores, coeffs):
    """(n, 6+32): [x1, y1, x2, y2, score, class, *coeffs] after class-aware NMS."""
    scores = scores[0]
    conf = scores.max(axis=0)
    idx = np.flatnonzero(conf > CONF)
    if not len(idx):
        return np.zeros((0, 6 + coeffs.shape[1]), dtype=np.float32)
    cls = scores[:, idx].argmax(axis=0)
    conf = conf[idx]
    cx, cy, w, h = boxes[0][:, idx]
    xyxy = np.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], axis=1)
    off = xyxy + cls[:, None] * 7680.0
    keep = cv2.dnn.NMSBoxes(
        np.column_stack([off[:, :2], off[:, 2:] - off[:, :2]]).tolist(),
        conf.tolist(), CONF, IOU, top_k=300)
    keep = np.asarray(keep, dtype=np.int64).reshape(-1)
    return np.concatenate(
        [xyxy[keep], conf[keep, None], cls[keep, None].astype(np.float32),
         coeffs[0][:, idx[keep]].T], axis=1).astype(np.float32)


def _masks160(dets, proto):
    """Instance masks at prototype resolution, cropped to each box (x > 0 is
    sigmoid(x) > 0.5)."""
    c, mh, mw = proto.shape[1:]
    m = (dets[:, 6:] @ proto[0].reshape(c, -1) > 0).reshape(-1, mh, mw)
    ys = np.arange(mh, dtype=np.float32)[None, :, None]
    xs = np.arange(mw, dtype=np.float32)[None, None, :]
    s = mw / IMGSZ
    x1, y1, x2, y2 = (dets[:, i][:, None, None] * s for i in range(4))
    return m & (xs >= x1) & (xs < x2) & (ys >= y1) & (ys < y2)


class TorsoSegmenter:
    """Subject's torso mask with arms removed, at a requested output size."""

    def __init__(self, model=MODEL_PATH):
        self.sess = npu_session(model)

    def _letterbox(self, gray):
        """Gray sensor frame -> (1,3,640,640) blob, ultralytics-style letterbox.

        Returns the blob plus (scale, pad_x, pad_y) to map 640-space back."""
        h, w = gray.shape
        r = IMGSZ / max(h, w)
        nw, nh = round(w * r), round(h * r)
        px, py = (IMGSZ - nw) // 2, (IMGSZ - nh) // 2
        canvas = np.full((IMGSZ, IMGSZ), 114, np.uint8)
        canvas[py:py + nh, px:px + nw] = cv2.resize(gray, (nw, nh),
                                                    interpolation=cv2.INTER_LINEAR)
        blob = np.repeat((canvas.astype(np.float32) / 255.0)[None, None], 3, axis=1)
        return blob, (r, px, py, nw, nh)

    def instances(self, gray, out_size):
        """Every torso in frame, as masks (uint8 0/255, arms removed) at out_size.

        Arm masks are subtracted after a dilation so an arm across the chest
        does not bleed into the torso surface. Which instance is the subject is
        `pick_subject`'s call, not the model's: the class can flip between
        frames, the geometry does not."""
        blob, (r, px, py, nw, nh) = self._letterbox(gray)
        boxes, scores, coeffs, proto = self.sess.run(None, {"images": blob})
        dets = _decode(boxes, scores, coeffs)
        if not len(dets):
            return []
        masks = _masks160(dets, proto)
        cls = dets[:, 5].astype(int)

        # Crop the letterbox padding off at 160x160, then resize to out_size.
        s = proto.shape[-1] / IMGSZ
        y0, y1 = int(round(py * s)), int(round((py + nh) * s))
        x0, x1 = int(round(px * s)), int(round((px + nw) * s))
        W, H = out_size

        def up(m):
            return cv2.resize(m[y0:y1, x0:x1].astype(np.uint8), (W, H),
                              interpolation=cv2.INTER_NEAREST)

        arms = np.zeros((H, W), np.uint8)
        for i in np.flatnonzero(cls == ARM):
            arms |= up(masks[i])
        if arms.any():
            k = max(3, int(round(ARM_EXCLUDE_DILATE_PX * W / 1280)) | 1)
            kern = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
            arms = cv2.dilate(arms, kern)
        out = []
        for i in np.flatnonzero(cls == TORSO):
            torso = up(masks[i]) * 255
            torso[arms > 0] = 0
            if torso.any():
                out.append(torso)
        return out

    def __call__(self, gray, out_size):
        """Torso mask of the centre-most person, or None. No subject lock."""
        return pick_subject(self.instances(gray, out_size))[0]


def _centroid(mask):
    m = cv2.moments(mask, binaryImage=True)
    if not m["m00"]:
        return None
    return m["m10"] / m["m00"], m["m01"] / m["m00"]


def mask_iou(a, b):
    both = np.count_nonzero((a > 0) & (b > 0))
    return both / max(np.count_nonzero((a > 0) | (b > 0)), 1)


def pick_subject(masks, lock=None, min_iou=0.3):
    """(mask, index) of the subject among `masks`, or (None, None).

    With no `lock`, the person whose centroid is nearest the image centre.
    With one (the subject's previous mask), the person overlapping it most, and
    only if the overlap is at least `min_iou`: somebody else walking into the
    centre is then not mistaken for the subject, the subject is reported lost."""
    if not masks:
        return None, None
    if lock is not None:
        ious = [mask_iou(m, lock) for m in masks]
        best = int(np.argmax(ious))
        return (masks[best], best) if ious[best] >= min_iou else (None, None)
    best, best_d = None, None
    for i, m in enumerate(masks):
        c = _centroid(m)
        if c is None:
            continue
        h, w = m.shape
        d = float(np.hypot(c[0] / w - 0.5, c[1] / h - 0.5))
        if best_d is None or d < best_d:
            best, best_d = i, d
    return (masks[best], best) if best is not None else (None, None)
