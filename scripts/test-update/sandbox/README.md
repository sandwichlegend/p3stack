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

## Share within your tailnet

Set the HTTPS origin that `tailscale serve` exposes, then start the server:

```sh
SANDBOX_URL=https://machine.tailnet.ts.net npm start
```

Proxy that origin to `http://127.0.0.1:4317` with Tailscale Serve. Open either token link printed at startup. When `SANDBOX_URL` is set, loopback requests also require the token or access cookie. The server sets an access cookie and redirects to a URL without the token. Restarting the server changes the token and invalidates old cookies. Never set `SANDBOX_URL` to a public URL or a Tailscale Funnel URL.

At most eight sessions can be open, including sessions still being built. Session creation is limited to 12 requests per minute per connecting address. A session closes after 15 minutes without terminal input or output. A Tailscale proxy shares its request limit across users.

## Isolation

The server listens on 127.0.0.1. By default it accepts only that loopback Host and Origin. `SANDBOX_URL` adds exactly one HTTPS Host and Origin for a private Tailscale Serve proxy. When `SANDBOX_URL` is set, every request requires authentication, including loopback requests. Open a printed token link to set an HttpOnly, SameSite cookie. The HTTPS tailnet cookie also has the Secure flag. Unlisted hosts, mismatched origins, and missing or invalid tokens receive 403 responses. It runs fixtures and shells inside Bubblewrap with an empty inherited environment, separate process and network namespaces, and no host home directory mount. The checkout and selected system tools and their runtime libraries are read only. Host application directories are absent. Only each session's scratch directory is a writable host mount. Temporary files outside that mount live in disposable namespace filesystems.

HOME, tool config folders, the release repository, its bare origin, the installer's clone, and saved edits stay inside the scratch directory. PATH contains the fixture's fake agents and selected normal utilities. The wrapper runs this checkout's CLI and disables its npm handoff. The sandbox cannot reach the host's user-installed agents or network services.

This is a local fixture playground, not a service for untrusted users. Selected system libraries and files under `/etc` are visible read only. It requires Bubblewrap and does not fall back to a shell that can write to your home.

## Verify the sandbox

Run `npm test` to load all seventeen scenarios, drive the real CLI in pseudo-terminals, check both fake merge results, and attempt writes outside scratch. The checks also confirm that the host home and embedded Codex executable are absent. HTTP tests cover Host, Origin, loopback token, and cookie rejection, malformed JSON, unknown scenarios that do not consume the creation limit, query strings, concurrent session limits, request rate limits, and idle expiry refreshed by input and output.
