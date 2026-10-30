"""Constants that GDScript and Python each keep a copy of must agree.

The app and the tracker are two programs in two languages, so a few values live
twice: the link's protocol VERSION, the movement each game trains, and the
folder under Documents that every file goes to. Nothing at runtime notices when
one copy changes and the other does not — a VERSION mismatch only shows as a
tablet that will not connect, a MOVEMENT mismatch as sessions rebuilt with the
wrong movement, an app folder mismatch as a tracker reading another branch's
settings. These read each copy from source, without importing anything.

    python pyscripts/tests/test_parity.py
"""
import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def gd_const(path, name):
    """The literal after `const NAME :=` in a GDScript file, as Python sees it."""
    text = (ROOT / path).read_text(encoding="utf-8")
    # Up to the next line that starts at column 0 and is not a closing bracket.
    match = re.search(rf"^const {name}\s*:?=\s*(.+?)(?=^[^\s\]}}])", text + "\nEOF", re.M | re.S)
    assert match, f"no const {name} in {path}"
    # GDScript dict/array/number/string literals are valid Python once comments go.
    literal = re.sub(r"#[^\n]*", "", match.group(1)).strip()
    return ast.literal_eval(literal)


def py_const(path, name):
    """A module-level `NAME = <literal>` in a Python file, without importing it."""
    tree = ast.parse((ROOT / path).read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise AssertionError(f"no {name} in {path}")


def test_protocol_version():
    gd = gd_const("Main_screen/Scripts/link_protocol.gd", "VERSION")
    py = py_const("pyscripts/protocol.py", "VERSION")
    assert gd == py, f"link_protocol.gd VERSION {gd} != protocol.py VERSION {py}"
    print(f"  protocol VERSION         {gd} in both")


def test_movement_per_game():
    gd = gd_const("Main_screen/Scripts/session_log.gd", "MOVEMENT")
    py = py_const("pyscripts/rebuild_sessions.py", "MOVEMENT")
    assert gd == py, f"session_log.gd MOVEMENT {gd} != rebuild_sessions.py MOVEMENT {py}"
    print(f"  MOVEMENT                 {len(gd)} games in both")


# `Path.home() / "Documents" / "X"` and `Path("/home/radxa/Documents/X/...")`.
APP_DIR_PATTERNS = (
    re.compile(r'"Documents"\s*/\s*"([^"]+)"'),
    re.compile(r'Path\("[^"]*/Documents/([^/"]+)'),
)


def test_app_dir():
    app_dir = gd_const("Main_screen/Scripts/settings.gd", "APP_DIR")
    sources = [*ROOT.glob("*.py"), *(ROOT / "pyscripts").rglob("*.py")]
    found = {}
    for path in sources:
        if path.resolve() == Path(__file__).resolve():
            continue   # the patterns' own comment above
        text = path.read_text(encoding="utf-8")
        for pattern in APP_DIR_PATTERNS:
            for match in pattern.finditer(text):
                found.setdefault(match.group(1), []).append(path.relative_to(ROOT).as_posix())
    assert found, "no Python file names the app folder; the pattern needs updating"
    wrong = {name: files for name, files in found.items() if name != app_dir}
    assert not wrong, f"settings.gd APP_DIR is {app_dir!r}, but Python uses {wrong}"
    print(f"  app folder               {app_dir!r} in settings.gd and "
          f"{len({f for files in found.values() for f in files})} Python files")


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
    print("\nOK — GDScript and Python agree.")
