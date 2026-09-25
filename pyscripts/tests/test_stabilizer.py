"""What the corner deadband may and may not freeze.

The stabilizer holds the previous pose when the corners it was solved from have
barely moved. The subtle case is not movement but *membership*: the set of views
feeding the solve changes as tags come in and out of sight, and a pose solved
from one set is not an answer for another.

A tag arriving was always handled — it has no stored corners, so it reads as not
static. A tag leaving was not: it simply stopped being iterated over, so the
pose solved from it stayed frozen while the remaining tags held still. On this
rig, where tags disagree about the tracked point by several mm, that is a stale
answer held indefinitely, not a harmless one.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from corner_stabilizer import CornerStabilizer

STILL = np.zeros((4, 2))
ELSEWHERE = np.ones((4, 2)) * 10.0


def run(threshold=1.0):
    stabilizer = CornerStabilizer(threshold_px=threshold)
    solves = []

    def solve_returning(value):
        def compute():
            solves.append(value)
            return np.array([value]), np.array([value])
        return compute

    return stabilizer, solves, solve_returning


def test_static_freezes():
    stabilizer, solves, solve = run()
    stabilizer.stabilize(-1, {"c0_1": STILL, "c0_2": ELSEWHERE}, solve(1))
    pose, _ = stabilizer.stabilize(-1, {"c0_1": STILL, "c0_2": ELSEWHERE}, solve(2))
    assert solves == [1], "a motionless body should not be re-solved"
    assert pose[0] == 1
    print("  unchanged corners        -> frozen")


def test_movement_resolves():
    stabilizer, solves, solve = run()
    stabilizer.stabilize(-1, {"c0_1": STILL}, solve(1))
    stabilizer.stabilize(-1, {"c0_1": STILL + 5.0}, solve(2))
    assert solves == [1, 2], "corners moved 5 px and were not re-solved"
    print("  corners moved            -> re-solved")


def test_tag_arriving_resolves():
    stabilizer, solves, solve = run()
    stabilizer.stabilize(-1, {"c0_1": STILL}, solve(1))
    stabilizer.stabilize(-1, {"c0_1": STILL, "c0_2": ELSEWHERE}, solve(2))
    assert solves == [1, 2], "a newly visible tag must reach the solve"
    print("  a tag came into view     -> re-solved")


def test_tag_leaving_resolves():
    stabilizer, solves, solve = run()
    stabilizer.stabilize(-1, {"c0_1": STILL, "c0_2": ELSEWHERE}, solve(1))
    pose, _ = stabilizer.stabilize(-1, {"c0_1": STILL}, solve(2))
    assert solves == [1, 2], (
        "a tag left view and the pose solved from it was held — the stale case"
    )
    assert pose[0] == 2
    print("  a tag left view          -> re-solved")


def test_freezes_again_after_membership_settles():
    """The set changing must cost one solve, not disable the deadband."""
    stabilizer, solves, solve = run()
    stabilizer.stabilize(-1, {"c0_1": STILL, "c0_2": ELSEWHERE}, solve(1))
    stabilizer.stabilize(-1, {"c0_1": STILL}, solve(2))
    stabilizer.stabilize(-1, {"c0_1": STILL}, solve(3))
    assert solves == [1, 2], "the deadband stopped working after a tag left"
    print("  set settled again        -> frozen")


def test_views_are_independent():
    """cam1 moving must re-solve a pose that cam1 contributes to."""
    stabilizer, solves, solve = run()
    stabilizer.stabilize(-1, {"c0_1": STILL, "c1_1": STILL}, solve(1))
    stabilizer.stabilize(-1, {"c0_1": STILL, "c1_1": STILL + 5.0}, solve(2))
    assert solves == [1, 2], "movement in the second view was ignored"
    print("  one view moved           -> re-solved")


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
    print("\nOK — the deadband freezes only a genuinely repeated measurement.")
