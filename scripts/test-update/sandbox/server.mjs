import http from "node:http"
import { readFile, mkdtemp, mkdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { randomUUID } from "node:crypto"
import * as pty from "node-pty"
import { isolation, prepare } from "./sandbox.mjs"
import { scenarios } from "./scenarios.mjs"

const port = Number(process.env.PORT || 4317)
const origin = `http://127.0.0.1:${port}`
const root = await mkdtemp(join(tmpdir(), "p3stack-sandbox-"))
const sessions = new Map()
const assets = new Map([
  ["/", ["index.html", "text/html"]],
  ["/client.mjs", ["client.mjs", "text/javascript"]],
  ["/style.css", ["style.css", "text/css"]],
  ["/xterm.js", ["node_modules/@xterm/xterm/lib/xterm.js", "text/javascript"]],
  ["/fit.js", ["node_modules/@xterm/addon-fit/lib/addon-fit.js", "text/javascript"]],
  ["/xterm.css", ["node_modules/@xterm/xterm/css/xterm.css", "text/css"]],
])

function close(id) {
  const session = sessions.get(id)
  if (!session) return
  sessions.delete(id)
  clearTimeout(session.expiry)
  session.stream?.end()
  if (session.terminal) session.terminal.kill()
  else void rm(session.dir, { recursive: true, force: true })
}

async function body(req) {
  let text = ""
  for await (const chunk of req) {
    text += chunk
    if (text.length > 65536) throw new Error("Request too large")
  }
  return JSON.parse(text)
}

const server = http.createServer(async (req, res) => {
  res.setHeader("Cache-Control", "no-store")
  res.setHeader("X-Content-Type-Options", "nosniff")
  res.setHeader("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
  const json = (status, value) => {
    res.writeHead(status, { "Content-Type": "application/json" })
    res.end(JSON.stringify(value))
  }
  try {
    if (req.headers.host !== `127.0.0.1:${port}` || (req.headers.origin && req.headers.origin !== origin)) {
      return json(403, { error: "Use the loopback URL printed by npm start." })
    }
    if (req.method === "GET" && assets.has(req.url)) {
      const [path, type] = assets.get(req.url)
      const content = await readFile(new URL(path, import.meta.url))
      res.writeHead(200, { "Content-Type": type })
      return res.end(content)
    }
    if (req.method === "GET" && req.url === "/scenarios") return json(200, scenarios)
    if (req.method === "POST" && req.url === "/sessions") {
      const { scenario: name } = await body(req)
      const scenario = scenarios.find((item) => item.id === name)
      if (!scenario) return json(400, { error: "Unknown scenario" })
      const id = randomUUID()
      const dir = join(root, id)
      await mkdir(dir)
      try {
        await prepare(dir, scenario)
      } catch (error) {
        await rm(dir, { recursive: true, force: true })
        throw error
      }
      sessions.set(id, { dir, expiry: setTimeout(() => close(id), 30000) })
      return json(201, { id, scratch: `${dir}/work` })
    }
    const match = req.url.match(/^\/sessions\/([a-f0-9-]+)(\/events|\/input|\/resize)?$/)
    const session = match && sessions.get(match[1])
    if (!session) return json(404, { error: "Session not found" })
    const id = match[1]
    if (req.method === "DELETE" && !match[2]) {
      close(id)
      return json(200, {})
    }
    if (req.method === "GET" && match[2] === "/events" && !session.terminal) {
      clearTimeout(session.expiry)
      res.writeHead(200, { "Content-Type": "text/event-stream", "Connection": "keep-alive" })
      res.flushHeaders()
      session.stream = res
      session.terminal = pty.spawn("bwrap", [...isolation(session.dir), "/bin/bash", "--noprofile", "--rcfile", "/sandbox/shell.rc", "-i"], {
        name: "xterm-256color", cols: 100, rows: 32, cwd: session.dir, env: {},
      })
      session.terminal.onData((data) => res.write(`data: ${JSON.stringify(data)}\n\n`))
      session.terminal.onExit(({ exitCode }) => {
        res.write(`event: exit\ndata: ${exitCode}\n\n`)
        res.end()
        sessions.delete(id)
        void rm(session.dir, { recursive: true, force: true })
      })
      res.on("close", () => close(id))
      return
    }
    if (req.method === "POST" && session.terminal) {
      const value = await body(req)
      if (match[2] === "/input" && typeof value.data === "string") session.terminal.write(value.data)
      else if (match[2] === "/resize" && Number.isInteger(value.cols) && Number.isInteger(value.rows)
        && value.cols >= 20 && value.cols <= 500 && value.rows >= 5 && value.rows <= 200) session.terminal.resize(value.cols, value.rows)
      else return json(400, { error: "Invalid terminal message" })
      return json(200, {})
    }
    json(405, { error: "Method not allowed" })
  } catch (error) {
    console.error(error.message)
    if (!res.headersSent) json(500, { error: error.message })
    else res.end()
  }
})

server.listen(port, "127.0.0.1", () => console.log(`Update sandbox: ${origin}\nScratch: ${root}\nRequires Linux, Bubblewrap, and unprivileged user namespaces. Ctrl-C stops all terminals.`))
server.on("error", async (error) => {
  console.error(error.message)
  await rm(root, { recursive: true, force: true })
  process.exit(1)
})
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => {
  for (const id of sessions.keys()) close(id)
  server.close()
  server.closeAllConnections()
  setTimeout(async () => {
    await rm(root, { recursive: true, force: true })
    process.exit(0)
  }, 200)
})
