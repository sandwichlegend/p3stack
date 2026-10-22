#!/usr/bin/env node
import { spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
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
    const done = (value) => {
      stdin.setRawMode(false)
      stdin.pause()
      stdin.off("data", onKey)
      stdout.write("\x1b[?25h")
      resolve(value)
    }
    const onKey = (key) => {
      if (key === "\x03" || key === "q" || key === "\x1b") return done(null)
      if (key === "\r" || key === "\n") return done(items.map((item) => item.value).filter((v) => selected.has(v)))
      if (key === "\x1b[A" || key === "k") cursor = (cursor + items.length - 1) % items.length
      if (key === "\x1b[B" || key === "j") cursor = (cursor + 1) % items.length
      if (key === " ") {
        const value = items[cursor].value
        selected.has(value) ? selected.delete(value) : selected.add(value)
      }
      if (key === "a") {
        const all = selected.size === items.length
        items.forEach((item) => (all ? selected.delete(item.value) : selected.add(item.value)))
      }
      draw()
    }
    stdout.write("\x1b[?25l")
    stdin.setRawMode(true)
    stdin.setEncoding("utf8")
    stdin.on("data", onKey)
    stdin.resume()
    draw()
  })
}

const newer = (a, b) => {
  const [x, y] = [a, b].map((v) => v.split(".").map(Number))
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i]
  return false
}

// A global install, or an npx cache on older npm, can run a stale copy. Hand off to the published latest so `npx p3stack update` never needs @latest.
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

const argv = process.argv.slice(2)
const { action, chosen } = parse(argv)
await runLatest(argv)
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

process.exit(bash([action, ...picked], { stdio: "inherit" }).status ?? 1)
