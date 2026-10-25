# Real plugin CLI captures

These captures use Claude Code 2.1.310, Codex 0.164.0, OpenCode 2.1.4, and Cursor Agent 2026.10.16-e3cb207. Each command ran in a temporary HOME with CLAUDE_CONFIG_DIR, CODEX_HOME, and XDG config, cache, data, and state directories under that HOME. `<HOME>` replaces only that temporary path. Files include the command and exit status. Layout files omit mise's own installation files and git internals.

Codex lists every available marketplace plugin, including rows with STATUS `not installed`. Its JSON has installed and available arrays but no per-plugin source commit. Cache folders use `1.0.0`. The first empty-HOME probes record the error when CODEX_HOME does not exist. Lifecycle probes create it first.

Claude's JSON includes the active installPath, timestamps, and enabled flags. Cache folders use the first twelve commit characters. Uninstall retains those folders.

OpenCode add and remove change configuration while retaining timestamped package caches. Its list command prints `ID VERSION SOURCE` rows or `No plugins found`. It has no JSON listing or marketplace command. A separate service port was necessary for the isolated probes. Configuration changes can take several commands to reach the service. The observed-1 through observed-4 captures retain that behavior, including initially empty listings after add. The observed-3 capture is the populated listing contract.

Cursor Agent exposes marketplace commands, but listing marketplaces requires login. Its plugin command does not expose install, list, update, or remove. The installer manages Cursor's local folders itself.

`fake_listings_match_real_captures` compares fake output to these captures, normalizing only HOME, commit IDs, and timestamps. The captures are evidence from real tools, not generated expected output.

Round 5 adds fresh marketplace listings for all four tools, the Codex missing-home error, Codex marketplace file replacement, and OpenCode package folders before and after update. The Codex replacement probe writes a marker into the installed skill, upgrades the marketplace, and checks that the marker is gone. The OpenCode probe waits for its listing to catch up before update and observes the same package folder afterward.

The test helpers require a temporary HOME and all config directories inside it. Fixtures accept only a new, empty temporary target, create their home with mktemp, and publish env.sh by atomic rename. Consumers check that file before sourcing it. Fake tools require the home marker written by the helper. A missing env file cannot fall back to the caller's home.
