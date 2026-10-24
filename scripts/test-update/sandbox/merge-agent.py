#!/usr/bin/env python3
import difflib
from pathlib import Path

print(f"\nSandbox merge agent in {Path.cwd()}\n")
print("Files: " + ", ".join(sorted(path.name for path in Path.cwd().iterdir())))
print(Path("BRIEF.md").read_text())
yours = next(Path.cwd().glob("yours*"))
suffix = yours.suffix
base = Path(f"original{suffix}")
if not base.exists():
    raise SystemExit("No original file. No result was written.")
original = base.read_text().splitlines(keepends=True)
local = yours.read_text().splitlines(keepends=True)
upstream = Path(f"theirs{suffix}").read_text().splitlines(keepends=True)
edits = []
for version in (local, upstream):
    for tag, start, end, new_start, new_end in difflib.SequenceMatcher(None, original, version).get_opcodes():
        if tag != "equal":
            edit = (start, end, version[new_start:new_end])
            if edit not in edits:
                edits.append(edit)
edits.sort(key=lambda edit: (edit[0], edit[1]))
result = []
cursor = 0
for start, end, lines in edits:
    if start < cursor:
        raise SystemExit("Overlapping edits need a real merge. No result was written.")
    result.extend(original[cursor:start])
    result.extend(lines)
    cursor = end
result.extend(original[cursor:])
output = Path(f"result{suffix}")
output.write_text("".join(result))
print(f"\nWrote {output.name}. Kept your changes and the release changes. No model was called.\n")
