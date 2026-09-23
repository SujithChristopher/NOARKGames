"""Two OV9281s captured as a synchronised pair.

Both the tracker and the rigid-body calibration need the same thing from the
cameras: a frame from each, taken at the same instant, with the pairing proven
rather than assumed. Getting that right is subtle enough — sensor phase, V4L2
queue alignment, crystal drift — that it lives here once instead of being
reimplemented either side and drifting apart.

Two separate problems have to be solved, and only the first is obvious:

* **Sensor phase.** The two sensors self-clock off separate 24 MHz crystals
  with no FSIN wiring, so they free-run at an arbitrary phase — cold, that can
  be most of a frame period. `rcam.FrameSync` walks one onto the other by
  briefly stretching its vertical blanking, and the ~50 ppm the crystals differ
  by is topped up as the session runs.

* **Queue alignment.** Each camera buffers its own frames and hands back the
  *oldest*, so a camera that started streaming earlier stays permanently ahead.
  Draining both in step preserves that offset forever. Measured on this board
  it sits at just under three frame periods — 47 ms — and an unsynchronised
  capture loop pairs frames that far apart on every single frame, while
  userspace arrival times show nothing wrong because both grabs return "now".

The kernel's frame timestamps are what make the second problem visible:
CLOCK_MONOTONIC as stamped by CAMSS in its frame-done interrupt, ~100 us of
jitter against the 1-2 ms a userspace arrival time carries.
"""

import time
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

import collections
import threading

import cv2  # noqa: F401 - kept for parity with callers' expectations
import numpy as np


class StereoCapture:
    """Both cameras, phase-aligned and queue-paired, as one source of frames."""

    PHASE_WINDOW = 90   # frames of timestamp history the phase/resync fit uses

    def __init__(
        self,
        frame_size,
        fps_value: Optional[int] = None,
        frame_sync: bool = True,
        phase_tol_us: float = 200.0,
        resync_threshold_us: float = 1000.0,
        exposure_us: int = 10000,
        gain: float = 1.0,
        isp: Optional[str] = None,
        on_stage=None,
    ) -> None:
        self.frame_size          = frame_size
        self.fps_value           = fps_value
        self.frame_sync_enabled  = frame_sync
        self.phase_tol_us        = phase_tol_us
        self.resync_threshold_us = resync_threshold_us
        self.exposure_us         = exposure_us
        self.gain                = gain
        # rcam's software port of the Pi's mono pipeline: black level, digital
        # gain and the ov9281_mono gamma curve, folded into the unpack LUT.
        # "pisp" (Pi 5 curve) or "vc4" (Pi 4), or None for the raw high byte.
        self.isp                 = isp
        # Called between bring-up stages. Raising from it aborts startup and
        # releases the cameras — which is how a quit arriving during the tens of
        # seconds of phase alignment gets honoured instead of ignored.
        self._on_stage           = on_stage or (lambda: None)

        self.cam0 = None   # primary (tracking + display)
        self.cam1 = None   # stereo second view
        self._executor         = None
        self._frame_period_us  = 0.0
        self._skew_baseline_us = 0.0   # measured cam0->cam1 sensor phase offset
        self._frame_sync   = None      # rcam.FrameSync once both cameras are up
        self._resync_busy  = threading.Event()
        self._recent_ns    = (
            collections.deque(maxlen=self.PHASE_WINDOW),
            collections.deque(maxlen=self.PHASE_WINDOW),
        )
        self._last_seq = [None, None]
        # The driver's frame counter for the pair next_pair() just returned.
        # Kept here rather than widened into the return tuple, which every
        # caller would have to change; the recorder reads it straight after.
        self.last_sequence = [None, None]
        self._dropped  = [0, 0]    # frames the sensors made that never arrived
        self._repairs  = 0         # times the capture queues had to be re-paired

        self._init_cameras()

    # ── What callers use ──────────────────────────────────────────────────────

    @property
    def frame_period_us(self) -> float:
        return self._frame_period_us

    @property
    def skew_baseline_us(self) -> float:
        return self._skew_baseline_us

    @property
    def dropped(self):
        return list(self._dropped)

    @property
    def repairs(self) -> int:
        return self._repairs

    def reset_counters(self) -> None:
        self._dropped = [0, 0]
        self._repairs = 0

    def next_pair(self):
        """One simultaneous frame from each camera.

        Returns ``(frame0, frame1, ts0, ts1, paired)``. A pair whose skew has
        slipped a whole frame is caught back up from the lagging camera's queue
        where possible; ``paired`` says whether what is returned is actually
        simultaneous, so callers can decline to triangulate the ones that are
        not rather than silently fusing two different instants.
        """
        raw0, raw1, ts0, ts1 = self._capture_pair()
        if abs((ts1 - ts0) / 1000.0 - self._skew_baseline_us) >= 0.5 * self._frame_period_us:
            raw0, raw1, ts0, ts1 = self._catch_up(raw0, raw1, ts0, ts1)
        skew_us = (ts1 - ts0) / 1000.0
        paired = abs(skew_us - self._skew_baseline_us) < 0.5 * self._frame_period_us
        return raw0, raw1, ts0, ts1, paired

    def maybe_resync(self) -> None:
        """Top up the phase alignment; safe to call on every loop iteration."""
        if self._frame_sync is not None and self.frame_sync_enabled:
            self._resync()

    def phase_report(self):
        return self._phase_now()

    def close(self) -> None:
        for cam in (self.cam0, self.cam1):
            if cam is not None:
                cam.stop()
        if self._executor is not None:
            self._executor.shutdown(wait=True)

    # ── Cameras ───────────────────────────────────────────────────────────────

    def _init_cameras(self) -> None:
        from rcam import Camera, list_cameras

        labels = list_cameras()
        if len(labels) < 2:
            raise RuntimeError(
                f"Stereo tracking requires two OV9281 cameras; found {labels or 'none'} "
                "(is the driver loaded? try: sudo modprobe ov9282)"
            )

        # No FrameRate control means the sensor free-runs at whatever rate its
        # current exposure/blanking allows — i.e. max achievable fps.
        cam_controls = {
            "ExposureTime": self.exposure_us,
            "AnalogueGain": self.gain,
        }
        if self.isp is not None:
            # The ISP path starts with AE on, as a Pi does. Left there the two
            # cameras meter independently and can settle on different
            # exposures, which is not what a stereo pair wants, so pin it.
            cam_controls["AeEnable"] = False
        if self.fps_value is not None:
            cam_controls["FrameRate"] = self.fps_value

        self.cam0 = Camera(labels[0])
        self.cam0.configure(size=self.frame_size, bit_depth=8, isp=self.isp)
        self.cam0.set_controls(cam_controls)
        self.cam0.start()

        # cam1 is always active — used for stereo_pnp on every frame
        self.cam1 = Camera(labels[1])
        self.cam1.configure(size=self.frame_size, bit_depth=8, isp=self.isp)
        self.cam1.set_controls(cam_controls)
        self.cam1.start()

        # The driver clips exposure to what the current blanking allows, so say
        # what the sensor actually took rather than what was asked for.
        for label, cam in (("cam0", self.cam0), ("cam1", self.cam1)):
            try:
                actual = cam.get_control("exposure") * cam.line_time_us()
            except Exception:  # v4l2-ctl fallback cannot read it back
                continue
            note = ""
            if abs(actual - self.exposure_us) > 0.02 * self.exposure_us:
                note = f"  (clipped from {self.exposure_us} us)"
            print(f"[CAM] {label}: exposure {actual:.0f} us, gain {self.gain:.1f}x{note}")

        # Concurrent grab: issue both captures in parallel so the inter-camera
        # gap collapses to the sensors' fixed phase offset (not a full frame).
        self._executor = ThreadPoolExecutor(max_workers=2)

        try:
            self._on_stage()
            self._init_frame_sync()
            self._on_stage()
            self._align_pairing()
            self._on_stage()
            self._measure_phase_offset(60)  # fixed sample, independent of target fps
        except BaseException:
            # Half-configured cameras still hold the video nodes, and the next
            # run would find them busy.
            self.close()
            raise

    # ── Frame synchronisation ─────────────────────────────────────────────────

    def _init_frame_sync(self) -> None:
        """Bring cam1's frame phase onto cam0's before tracking starts.

        The two sensors self-clock off separate 24 MHz crystals with no FSIN
        wiring between them, so they free-run at an arbitrary phase — cold, that
        can be most of a frame period. Stereo triangulation of a *moving* marker
        then fuses two different instants, which shows up as a position error
        proportional to hand speed (half a frame at 90 fps is ~5.5 ms).

        rcam.FrameSync walks cam1 onto cam0 by briefly stretching its vertical
        blanking, which lands the pair inside ~100 µs. The crystals still differ
        by ~50 ppm (~3 ms/minute), so run() tops the alignment up from the
        sensor timestamps as they arrive — see _resync().
        """
        from rcam import FrameSync

        try:
            self._frame_sync = FrameSync(self.cam0, self.cam1)
        except RuntimeError as exc:
            # The v4l2-ctl fallback backend exposes no buffer timestamps, so
            # there is nothing to measure a phase from. Tracking still works;
            # the sensors just free-run and the skew gating falls back to
            # software arrival times.
            print(f"[SYNC] Frame sync unavailable: {exc}")
            self._frame_sync = None
            return

        self._frame_period_us = self._frame_sync.period_us
        if not self.frame_sync_enabled:
            print("[SYNC] Frame sync disabled (--no-frame-sync); sensors free-run.")
            return

        print(
            f"[SYNC] Aligning cam1 → cam0 "
            f"({self._frame_period_us / 1000:.2f} ms frame period, "
            f"{self._frame_sync.line_time_us:.2f} µs/line):"
        )
        self._frame_sync.align(tol_us=self.phase_tol_us)

    def _drain(self, cam, n: int) -> None:
        """Discard n queued frames from one camera without copying pixels out."""
        for _ in range(n):
            try:
                cam.capture_meta()
            except RuntimeError:       # v4l2-ctl fallback has no capture_meta
                cam.capture_buffer()

    def _pair_slip(self, n_pairs: int = 15) -> float:
        """Median cam0→cam1 skew over n_pairs, in µs."""
        skews = sorted((ts1 - ts0) / 1000.0
                       for _, _, ts0, ts1 in
                       (self._capture_pair() for _ in range(max(1, n_pairs))))
        return skews[len(skews) // 2]

    def _align_pairing(self, max_iters: int = 4) -> None:
        """Pair the two capture queues on the same frame, not just the same phase.

        Aligning the sensors puts both exposures at the same instant, but each
        camera has its own V4L2 buffer queue and capture_array_meta() returns
        the *oldest* one. cam0 starts streaming while cam1 is still being
        configured, so it banks several frames the other never had — measured
        cold, three. Draining both in step preserves that offset forever (which
        is why it survived every flush), and software arrival timestamps cannot
        see it at all: both grabs return "now" in userspace whether the buffer
        is fresh or 50 ms stale.

        The sensor timestamps make it visible as a skew of whole frame periods,
        and the fix is asymmetric: drop exactly that many frames from whichever
        camera is behind.
        """
        if not self._frame_period_us:
            return
        for _ in range(max_iters):
            skew_us = self._pair_slip()
            slip = int(round(skew_us / self._frame_period_us))
            if slip == 0:
                return
            # skew > 0 means cam1's frame is the newer one, i.e. cam0 is the
            # camera handing back stale buffers.
            lagging, count = (self.cam0, slip) if slip > 0 else (self.cam1, -slip)
            print(f"[SYNC] Capture queues {slip:+d} frames apart "
                  f"({skew_us / 1000:+.1f} ms) — dropping {count} stale frame(s)")
            self._drain(lagging, min(count, 8))

    def _catch_up(self, raw0, raw1, ts0: int, ts1: int, max_iters: int = 3):
        """Pull the lagging camera forward until the pair is simultaneous again.

        With the sensors free-running faster than this loop can consume them,
        the driver drops whichever frames don't fit in a camera's queue — and it
        doesn't drop the same ones on both, so the pairing slips a frame every
        few hundred frames and then stays slipped. Jitter is ~100 µs against a
        half-period of several ms, so a whole-frame slip is never noise.

        Re-grabbing (rather than only draining) keeps the frame usable: the
        lagging camera's newer frames are already sitting in its queue, so this
        returns without waiting on the sensor, and the pair can still be
        triangulated instead of falling back to two single-camera poses.
        """
        for _ in range(max_iters):
            skew_us = (ts1 - ts0) / 1000.0
            slip = int(round((skew_us - self._skew_baseline_us) / self._frame_period_us))
            if slip == 0:
                break
            count = min(abs(slip), 8)
            if slip > 0:   # cam1's frame is the newer one, so cam0 is behind
                self._drain(self.cam0, count - 1)
                raw0, ts0, seq = self._grab(self.cam0)
                self.last_sequence[0] = seq
                self._note_meta(0, ts0, seq)
            else:
                self._drain(self.cam1, count - 1)
                raw1, ts1, seq = self._grab(self.cam1)
                self.last_sequence[1] = seq
                self._note_meta(1, ts1, seq)
            self._repairs += 1
        return raw0, raw1, ts0, ts1

    def _phase_now(self):
        """Inter-camera phase from the timestamps process_frame already kept.

        Pure arithmetic over the two deques — it takes no frames of its own, so
        it is safe to call from the reporting path mid-capture.
        """
        if self._frame_sync is None:
            return None
        from rcam import phase_from_timestamps

        stamps = [list(d) for d in self._recent_ns]
        if min(len(x) for x in stamps) < 10:
            return None
        return phase_from_timestamps(stamps[0], stamps[1], self._frame_sync.period_us)

    def _resync(self) -> None:
        """Top up the alignment against the ~50 ppm drift between the crystals.

        Runs on its own thread: a nudge is two v4l2-ctl calls around a sleep of
        roughly a frame period, and doing that inline would stall tracking for
        as long. The measurement itself takes no frames — it reuses the
        timestamps already collected — and the one stretched frame interval a
        nudge produces is absorbed by _catch_up() on the next pair.
        """
        if self._frame_sync is None or self._resync_busy.is_set():
            return
        stamps = [list(d) for d in self._recent_ns]
        if min(len(x) for x in stamps) < 30:
            return
        self._resync_busy.set()

        def work():
            try:
                report = self._frame_sync.resync_if_needed(
                    stamps[0], stamps[1], self.resync_threshold_us
                )
                if report is not None:
                    print(f"[SYNC] Phase was {report.phase_us:+.0f} µs — nudged")
            except Exception as exc:  # a failed nudge must not end the session
                print(f"[SYNC] Resync failed: {exc!r}")
            finally:
                self._resync_busy.clear()

        threading.Thread(target=work, name="resync", daemon=True).start()

    @staticmethod
    def _grab(cam):
        """Grab one frame plus the kernel's frame timestamp (ns) and sequence.

        The timestamp is CLOCK_MONOTONIC as stamped by CAMSS in its frame-done
        interrupt, so it carries ~100 µs of jitter rather than the 1–2 ms a
        userspace arrival time picks up. That is what lets the skew gate below
        tell a genuinely simultaneous pair from one that slipped a frame.
        `sequence` is the driver's frame counter: a gap in it means the sensor
        produced a frame that never reached us, which a timestamp gap alone
        cannot separate from this thread being descheduled.

        Both are None on rcam's v4l2-ctl fallback backend, where the buffer
        header isn't reachable — fall back to a software stamp there.
        """
        arr, ts_ns, seq = cam.capture_array_meta()
        if ts_ns is None:
            ts_ns = time.perf_counter_ns()
        return arr, ts_ns, seq

    def _note_meta(self, i: int, ts: int, seq: Optional[int]) -> None:
        """Record one camera's frame timestamp and account for skipped frames."""
        self._recent_ns[i].append(ts)
        if seq is not None:
            last = self._last_seq[i]
            if last is not None and seq - last > 1:
                self._dropped[i] += seq - last - 1
            self._last_seq[i] = seq

    def _capture_pair(self):
        """Grab both cameras concurrently; return (frame0, frame1, ts0, ts1) in ns."""
        f0 = self._executor.submit(self._grab, self.cam0)
        f1 = self._executor.submit(self._grab, self.cam1)
        frame0, ts0, seq0 = f0.result()
        frame1, ts1, seq1 = f1.result()
        self.last_sequence = [seq0, seq1]
        self._note_meta(0, ts0, seq0)
        self._note_meta(1, ts1, seq1)
        return frame0, frame1, ts0, ts1

    def _measure_phase_offset(self, n_frames: int) -> None:
        """Establish the baseline cam0→cam1 capture skew over n_frames.

        With frame sync applied this lands near zero and the gating in
        process_frame() is effectively "this pair is simultaneous"; with
        --no-frame-sync (or on the fallback backend) it is whatever phase the
        sensors happened to free-run into, and the gate still catches a pair
        that slipped a frame relative to that baseline.

        When no FrameSync is available the frame period isn't readable from the
        sensor either, so it is measured here — with no configured FrameRate
        target the real rate is whatever the sensor free-runs at, and the gating
        tolerance must scale off that, not off a requested value.
        """
        skews = []
        t_start = time.perf_counter()
        for _ in range(max(1, n_frames)):
            _, _, ts0, ts1 = self._capture_pair()
            skews.append((ts1 - ts0) / 1000.0)  # ns → µs
        if not self._frame_period_us:
            elapsed = time.perf_counter() - t_start
            self._frame_period_us = elapsed / len(skews) * 1_000_000
        self._skew_baseline_us = sum(skews) / len(skews)
        std = (sum((s - self._skew_baseline_us) ** 2 for s in skews) / len(skews)) ** 0.5
        pct = self._skew_baseline_us / self._frame_period_us * 100
        print(
            f"[SYNC] Phase offset: {self._skew_baseline_us:.0f} µs ± {std:.0f} µs "
            f"({pct:.1f}% of frame period). Stereo gated on deviation from baseline."
        )
