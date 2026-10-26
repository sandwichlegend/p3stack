import os
from pathlib import Path
import sys
import tempfile

CONFIG = {
    "CLAUDE_CONFIG_DIR": ".claude",
    "CODEX_HOME": ".codex",
    "XDG_CONFIG_HOME": ".config",
    "XDG_DATA_HOME": ".local/share",
    "XDG_CACHE_HOME": ".cache",
    "XDG_STATE_HOME": ".local/state",
}
# macOS links /tmp to /private/tmp, so compare resolved paths.
TMP = Path("/tmp").resolve()


def check(owned=False):
    home = Path(os.environ.get("HOME", "/")).resolve()
    if not home.is_relative_to(TMP) or home == TMP:
        raise ValueError(f"refusing: HOME={home}")
    for key in CONFIG:
        value = os.environ.get(key)
        if not value or not Path(value).resolve().is_relative_to(home) or Path(value).resolve() == home:
            raise ValueError(f"refusing: {key} must be inside HOME")
    if owned:
        marker = home / ".p3stack-test-home"
        if marker.is_symlink() or marker.read_text().strip() != str(home):
            raise ValueError("refusing: HOME was not created by the test helper")
    return home


def create(parent):
    check()
    if not str(parent).startswith("/tmp/") or not Path(parent).resolve().is_relative_to(TMP):
        raise ValueError("refusing: test folder must be inside /tmp")
    home = Path(tempfile.mkdtemp(prefix="home.", dir=parent))
    (home / ".p3stack-test-home").write_text(str(home.resolve()) + "\n")
    print(home)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "create":
            create(sys.argv[2])
        else:
            check(owned="--owned" in sys.argv)
    except (ValueError, OSError) as error:
        sys.exit(str(error))
