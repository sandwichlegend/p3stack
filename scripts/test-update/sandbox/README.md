# Try p3stack updates in a terminal

Requires Linux, Node.js 22 or newer, Python 3, Git, and Bubblewrap with unprivileged user namespaces enabled. Install Bubblewrap with your system package manager. If node-pty has no prebuilt binary for your platform, npm also needs a C++ compiler and make.

From this folder, run:

```sh
npm ci
npm start
```

Open http://127.0.0.1:4317. To use another port, run `PORT=4318 npm start` and use the printed URL.

Click a scenario. Type `p3stack update` in the terminal, then press Enter at the tool picker. Follow the card's instructions to answer the real update prompts. Reset reloads the selected fixture and discards that terminal's edits. Each tab has its own scratch directory.

Use `ls`, `cat`, `less`, `nano`, or another available editor to inspect and edit files between updates. Run `find "$HOME" -name SKILL.md` to locate installed skills. The terminal starts in `/sandbox/work`. The page shows the corresponding host scratch path.

Choose **Talk to a model**, then choose an agent. The fake agent prints the merge folder and brief, combines the fixture's independent changes into `result.md` or `result.ts`, and returns to the installer. It does not call a model. If you introduce overlapping edits, it refuses to write a result.

Press Ctrl-C in the server terminal to stop all shells and remove scratch data. Closing a browser tab also closes its shell.

## Isolation

The server listens on 127.0.0.1 and rejects requests with another Host or Origin. It runs fixtures and shells inside Bubblewrap with an empty inherited environment, separate process and network namespaces, and no host home directory mount. The checkout and selected system tools and their runtime libraries are read only. Host application directories are absent. Only each session's scratch directory is a writable host mount. Temporary files outside that mount live in disposable namespace filesystems.

HOME, tool config folders, the release repository, its bare origin, the installer's clone, and saved edits stay inside the scratch directory. PATH contains the fixture's fake agents and selected normal utilities. The wrapper runs this checkout's CLI and disables its npm handoff. The sandbox cannot reach the host's user-installed agents or network services.

This is a local fixture playground, not a service for untrusted users. Selected system libraries and files under `/etc` are visible read only. It requires Bubblewrap and does not fall back to a shell that can write to your home.

## Verify the sandbox

Run `npm test` to load all nine scenarios, drive the real CLI in pseudo-terminals, check both fake merge results, and attempt writes outside scratch. The checks also confirm that the host home and embedded Codex executable are absent.
