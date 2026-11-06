"""Following the rigid body: the window keeps the tags, and a lost body is found again."""
import sys
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
import rapidtag

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from body_search import REFRESH_FRAMES, BodySearch

DICTIONARY = "DICT_APRILTAG_36h11"
WIDTH, HEIGHT = 1280, 800
K = np.array([[600.0, 0, 640], [0, 600.0, 400], [0, 0, 1]])
D = np.zeros((4, 1))
TAGS = {1: (0, 0), 2: (140, 0), 3: (280, 10)}
SIZE = 100


def scene(x, y, tags=TAGS):
    image = np.full((HEIGHT, WIDTH), 255, np.uint8)
    dictionary = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11)
    for mid, (dx, dy) in tags.items():
        marker = cv2.aruco.generateImageMarker(dictionary, mid, SIZE - 20)
        marker = cv2.copyMakeBorder(marker, 10, 10, 10, 10, cv2.BORDER_CONSTANT, value=255)
        image[y + dy:y + dy + SIZE, x + dx:x + dx + SIZE] = marker
    return image


def search():
    params = rapidtag.DetectorParameters()
    params.corner_refinement_method = rapidtag.CORNER_REFINE_CONTOUR
    return BodySearch(DICTIONARY, params, (WIDTH, HEIGHT), ((K, D), (K, D)))


def step(tracker, frames, **pose):
    found = tracker.refine(tracker.find(frames))
    tracker.follow(found, **pose)
    return found


def test_window_follows_a_moving_body():
    tracker = search()
    for i in range(1, 40):
        x = 100 + i * 12
        found = step(tracker, (scene(x, 200), scene(x + 40, 260)))
        assert sorted(found[0][1]) == [1, 2, 3], f"frame {i}: {found[0][1]}"
        assert sorted(found[1][1]) == [1, 2, 3], f"frame {i}: {found[1][1]}"
        tag = dict(zip(found[0][1], found[0][0]))[1]
        assert abs(tag[:, 0].min() - (x + 10)) < 2, "corners must be in frame pixels"
    window = tracker.windows[0]
    assert (window[2] - window[0]) * (window[3] - window[1]) < WIDTH * HEIGHT / 2
    print("  moving body              -> every tag kept, corners in frame pixels")


def test_lost_body_is_found_again():
    tracker = search()
    step(tracker, (scene(100, 200), scene(100, 200)))
    assert tracker.windows[0] is not None
    # It jumps far outside the window, more than any motion margin allows.
    for _ in range(REFRESH_FRAMES + 2):
        found = step(tracker, (scene(800, 500), scene(800, 500)))
    assert sorted(found[0][1]) == [1, 2, 3] and sorted(found[1][1]) == [1, 2, 3]
    window = tracker.windows[0]
    assert window[0] > 600, "the window must have moved to where the body went"
    print("  body jumped away         -> found again")


def test_empty_view_searches_everything():
    tracker = search()
    blank = np.full((HEIGHT, WIDTH), 255, np.uint8)
    found = step(tracker, (blank, blank))
    assert found == [([], []), ([], [])] and tracker.windows == [None, None]
    assert tracker.full_searches == 2
    found = step(tracker, (scene(100, 200), scene(100, 200)))
    assert sorted(found[0][1]) == [1, 2, 3], "nothing to follow means a full search"
    print("  nothing in view          -> full search, and it comes into view")


def test_one_camera_rescued_while_the_other_follows():
    tracker = search()
    blank = np.full((HEIGHT, WIDTH), 255, np.uint8)
    step(tracker, (scene(100, 200), blank))
    assert tracker.windows[0] is not None and tracker.windows[1] is None
    saw = 0
    for _ in range(REFRESH_FRAMES + 1):
        found = step(tracker, (scene(100, 200), scene(600, 300)))
        saw += bool(found[1][1])
        if saw:
            break
    assert saw, "the camera that lost the body never searched in full"
    print("  one camera lost it       -> searched in full within a refresh period")


def test_pose_projects_into_the_window():
    # A tag not yet seen must be inside the window when the pose says it is there.
    tracker = search()
    half = 0.05
    square = np.array([[-half, -half, 0], [half, -half, 0], [half, half, 0], [-half, half, 0]])
    rig = SimpleNamespace(corners_reference={1: square, 9: square + [0.2, 0, 0]})
    found = [([], []), ([], [])]
    tracker.follow(found, rig, np.zeros(3), np.array([0.0, 0.0, 1.0]),
                   (np.eye(3), np.array([-0.077, 0.0, 0.0])))
    expected, _ = cv2.fisheye.projectPoints(
        (square + [0.2, 0, 0]).reshape(-1, 1, 3), np.zeros(3), np.array([0.0, 0.0, 1.0]), K, D)
    x0, y0, x1, y1 = tracker.windows[0]
    assert x0 <= expected[..., 0].min() and expected[..., 0].max() <= x1
    assert y0 <= expected[..., 1].min() and expected[..., 1].max() <= y1
    assert tracker.windows[1][2] < x1, "the other camera's window is offset by the baseline"
    print("  pose                     -> an unseen tag is inside the window, per camera")


def test_body_behind_the_camera_gives_no_window():
    tracker = search()
    rig = SimpleNamespace(corners_reference={1: np.array([[0.0, 0, 0], [0.1, 0, 0], [0.1, 0.1, 0], [0, 0.1, 0]])})
    tracker.follow([([], []), ([], [])], rig, np.zeros(3), np.array([0.0, 0.0, -1.0]), None)
    assert tracker.windows == [None, None]
    print("  body behind the camera   -> no window")


if __name__ == "__main__":
    test_window_follows_a_moving_body()
    test_lost_body_is_found_again()
    test_empty_view_searches_everything()
    test_one_camera_rescued_while_the_other_follows()
    test_pose_projects_into_the_window()
    test_body_behind_the_camera_gives_no_window()
    print("ok")
