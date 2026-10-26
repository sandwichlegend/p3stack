"""Usage: terminal.py <output file> <answers, comma separated> <command...>"""
import os
import pty
import select
import sys

sys.dont_write_bytecode = True

from importlib.util import spec_from_file_location, module_from_spec
from pathlib import Path
spec = spec_from_file_location("safe_home", Path(__file__).with_name("safe-home.py"))
safe_home = module_from_spec(spec)
spec.loader.exec_module(safe_home)
safe_home.check(owned=True)

out_path, answers, *command = sys.argv[1:]
answers = answers.split(",") if answers else []
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
output = b""
prompts = 0
while True:
    ready, _, _ = select.select([fd], [], [], 60)
    if not ready:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    output += data
    while output.count(b"Choose ") > prompts and answers:
        prompts += 1
        os.write(fd, (answers.pop(0) + "\r").encode())
_, status = os.waitpid(pid, 0)
with open(out_path, "wb") as f:
    f.write(output.replace(b"\r\n", b"\n"))
sys.exit(os.waitstatus_to_exitcode(status))
