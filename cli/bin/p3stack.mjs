#!/usr/bin/env node
import { spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { emitKeypressEvents } from "node:readline"
import { fileURLToPath } from "node:url"

const tools = {
  claude: "Claude Code",
  codex: "Codex",
  cursor: "Cursor",
  opencode: "OpenCode",
}
const actions = ["install", "update", "uninstall"]

// npm pack copies install.sh next to bin/. In a checkout, it sits at the repo root.
const installer = [new URL("../install.sh", import.meta.url), new URL("../../install.sh", import.meta.url)]
  .map(fileURLToPath)
  .find(existsSync)

const usage = `Install, update, or remove p3stack in the AI coding tools T3 Code runs.

Usage: npx p3stack [install|update|uninstall] [--all | --tools claude,codex,cursor,opencode]

  install    Add p3stack to the tools you pick (default)
  update     Pull the latest p3stack into the tools you pick
  uninstall  Remove p3stack from the tools you pick

Without --all or --tools, it asks which tools to use.`

function fail(message) {
  console.error(`p3stack: ${message}\n\n${usage}`)
  process.exit(2)
}

function parse(argv) {
  let action = "install"
  let chosen
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === "-h" || arg === "--help" || arg === "help") {
      console.log(usage)
      process.exit(0)
    } else if (actions.includes(arg) && i === 0) action = arg
    else if (arg === "--all") chosen = Object.keys(tools)
    else if (arg === "--tools" || arg.startsWith("--tools=")) {
      const value = arg === "--tools" ? argv[++i] : arg.slice("--tools=".length)
      if (!value) fail("--tools needs a list, such as --tools claude,codex")
      chosen = value.split(",").map((tool) => tool.trim()).filter(Boolean)
      if (!chosen.length) fail("--tools needs at least one tool, such as --tools claude,codex")
      const unknown = chosen.filter((tool) => !(tool in tools))
      if (unknown.length) fail(`unknown tool: ${unknown.join(", ")}`)
    } else fail(`unknown argument: ${arg}`)
  }
  return { action, chosen }
}

function bash(args, options) {
  const result = spawnSync("bash", [installer, ...args], options)
  if (result.error) {
    console.error(`p3stack: couldn't run bash: ${result.error.message}`)
    process.exit(1)
  }
  return result
}

function detect() {
  const result = bash(["detect"], { encoding: "utf8" })
  return result.stdout.split("\n").filter((tool) => tool in tools)
}

function pick(title, items) {
  const { stdin, stdout } = process
  const selected = new Set(items.map((item) => item.value))
  let cursor = 0
  let drawn = 0

  const draw = () => {
    if (drawn) stdout.write(`\x1b[${drawn}A\x1b[0J`)
    const lines = [
      title,
      ...items.map((item, i) => {
        const box = selected.has(item.value) ? "[x]" : "[ ]"
        const line = `${i === cursor ? ">" : " "} ${box} ${item.label}`
        return i === cursor ? `\x1b[36m${line}\x1b[0m` : line
      }),
      "\x1b[2m↑/↓ move · space toggle · a all · enter confirm · q quit\x1b[0m",
    ]
    stdout.write(lines.join("\n") + "\n")
    drawn = lines.length
  }

  return new Promise((resolve) => {
    const restore = () => {
      stdin.off("keypress", onKey)
      stdin.setRawMode(false)
      stdin.pause()
      stdout.write("\x1b[?25h")
    }
    const onSignal = (signal) => {
      restore()
      process.kill(process.pid, signal)
    }
    const signals = ["SIGTERM", "SIGHUP"]
    const done = (value) => {
      restore()
      process.off("exit", restore)
      signals.forEach((signal) => process.off(signal, onSignal))
      resolve(value)
    }
    const onKey = (_, key = {}) => {
      if ((key.ctrl && key.name === "c") || key.name === "q" || key.name === "escape") return done(null)
      if (key.name === "return" || key.name === "enter") return done(items.map((item) => item.value).filter((v) => selected.has(v)))
      if (key.name === "up" || key.name === "k") cursor = (cursor + items.length - 1) % items.length
      if (key.name === "down" || key.name === "j") cursor = (cursor + 1) % items.length
      if (key.name === "space") {
        const value = items[cursor].value
        selected.has(value) ? selected.delete(value) : selected.add(value)
      }
      if (key.name === "a") {
        const all = selected.size === items.length
        items.forEach((item) => (all ? selected.delete(item.value) : selected.add(item.value)))
      }
      draw()
    }
    process.once("exit", restore)
    signals.forEach((signal) => process.once(signal, onSignal))
    stdout.write("\x1b[?25l")
    emitKeypressEvents(stdin)
    stdin.setRawMode(true)
    stdin.on("keypress", onKey)
    stdin.resume()
    draw()
  })
}

function newer(latest, current) {
  const parse = (v) => v.match(/^(\d+)\.(\d+)\.(\d+)(-.+)?/)
  const [l, c] = [parse(latest), parse(current)]
  if (!l || !c) return false
  for (let i = 1; i <= 3; i++) if (+l[i] !== +c[i]) return +l[i] > +c[i]
  return Boolean(c[4]) && !l[4]
}

// A global install, or an npx cache on older npm, can run a stale copy. Hand off to the published latest so `npx p3stack update` never needs @latest.
// The handoff gets canonical arguments with no spaces, because Windows runs npx through cmd.exe, which would split quoted values.
async function runLatest(argv) {
  if (process.env.P3STACK_HANDOFF) return
  const { name, version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"))
  let latest
  try {
    const response = await fetch(`https://registry.npmjs.org/${name}/latest`, { signal: AbortSignal.timeout(3000) })
    if (!response.ok) return
    latest = (await response.json()).version
  } catch {
    return
  }
  if (typeof latest !== "string" || !newer(latest, version)) return
  console.log(`p3stack ${version} is out of date, so running ${latest}.\n`)
  const result = spawnSync("npx", ["--yes", `${name}@${latest}`, ...argv], {
    stdio: "inherit",
    env: { ...process.env, P3STACK_HANDOFF: "1" },
    shell: process.platform === "win32",
  })
  process.exit(result.status ?? 1)
}

const title = [
  "██████╗ ██████╗ ███████╗████████╗ █████╗  ██████╗██╗  ██╗",
  "██╔══██╗╚════██╗██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝",
  "██████╔╝ █████╔╝███████╗   ██║   ███████║██║     █████╔╝ ",
  "██╔═══╝  ╚═══██╗╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ",
  "██║     ██████╔╝███████║   ██║   ██║  ██║╚██████╗██║  ██╗",
  "╚═╝     ╚═════╝ ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝",
]

function banner() {
  const { stdout } = process
  if (!stdout.isTTY || stdout.columns < title[0].length) return
  const lines = process.env.NO_COLOR ? title : title.map((line) => `\x1b[36m${line}\x1b[0m`)
  stdout.write(`\n${lines.join("\n")}\n\n`)
}

const { action, chosen } = parse(process.argv.slice(2))
await runLatest([action, ...(chosen ? [`--tools=${chosen.join(",")}`] : [])])
banner()
if (!installer) {
  console.error("p3stack: install.sh is missing from this package. Reinstall with npx p3stack@latest.")
  process.exit(1)
}

let picked = chosen
if (!picked) {
  const found = detect()
  const missing = Object.keys(tools).filter((tool) => !found.includes(tool))
  if (!found.length) {
    console.error("p3stack: none of Claude Code, Codex, Cursor, or OpenCode was found on this machine.")
    process.exit(1)
  }
  if (missing.length) console.log(`Not found, so not listed: ${missing.map((tool) => tools[tool]).join(", ")}\n`)
  if (process.stdin.isTTY && process.stdout.isTTY) {
    picked = await pick(
      `Which tools should p3stack ${action === "install" ? "be installed in" : action === "update" ? "update in" : "be removed from"}?`,
      found.map((tool) => ({ value: tool, label: tools[tool] })),
    )
    if (picked === null) process.exit(130)
    if (!picked.length) {
      console.log("Nothing picked, so nothing changed.")
      process.exit(0)
    }
  } else picked = found
}

if (!picked.length) process.exit(1)
process.exit(bash([action, ...picked], { stdio: "inherit" }).status ?? 1)
