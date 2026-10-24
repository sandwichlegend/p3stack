import http from "node:http"
import { readFile, mkdtemp, mkdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto"
import * as pty from "node-pty"
import { isolation, prepare } from "./sandbox.mjs"
import { scenarios } from "./scenarios.mjs"

function tailnetOrigin(value) {
  if (!value) return undefined
  let url
  try { url = new URL(value) } catch { throw new Error("SANDBOX_URL must be an absolute HTTPS origin, such as https://machine.tailnet.ts.net") }
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash
    || ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) {
    throw new Error("SANDBOX_URL must be one non-loopback HTTPS origin with no credentials, path, query, or fragment")
  }
  return url
}

export async function startSandbox({ port = Number(process.env.PORT || 4317), sandboxUrl = process.env.SANDBOX_URL,
  idleMs = 15 * 60 * 1000, createLimit = 12, rateWindowMs = 60 * 1000, log = console.log } = {}) {
  const remote = tailnetOrigin(sandboxUrl)
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("PORT must be an integer from 0 to 65535")
  const token = remote ? randomBytes(32).toString("base64url") : undefined
  const root = await mkdtemp(join(tmpdir(), "p3stack-sandbox-"))
  const sessions = new Map()
  const attempts = new Map()
  const preparing = new Set()
  let origin
  const assets = new Map([
    ["/", ["index.html", "text/html"]],
    ["/client.mjs", ["client.mjs", "text/javascript"]],
    ["/style.css", ["style.css", "text/css"]],
    ["/xterm.js", ["node_modules/@xterm/xterm/lib/xterm.js", "text/javascript"]],
    ["/fit.js", ["node_modules/@xterm/addon-fit/lib/addon-fit.js", "text/javascript"]],
    ["/xterm.css", ["node_modules/@xterm/xterm/css/xterm.css", "text/css"]],
  ])

  function touch(id) {
    const session = sessions.get(id)
    if (!session) return
    clearTimeout(session.expiry)
    session.expiry = setTimeout(() => close(id), idleMs)
  }

  function close(id, terminalExited = false) {
    const session = sessions.get(id)
    if (!session) return
    sessions.delete(id)
    clearTimeout(session.expiry)
    session.stream?.end()
    if (session.terminal && !terminalExited) session.terminal.kill()
    else void rm(session.dir, { recursive: true, force: true })
  }

  function validToken(value) {
    return typeof value === "string" && Buffer.byteLength(value) === token.length
      && timingSafeEqual(Buffer.from(value), Buffer.from(token))
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
    res.setHeader("Referrer-Policy", "no-referrer")
    res.setHeader("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
    const json = (status, value) => {
      res.writeHead(status, { "Content-Type": "application/json" })
      res.end(JSON.stringify(value))
    }
    try {
      const expectedOrigin = req.headers.host === new URL(origin).host ? origin
        : remote && req.headers.host === remote.host ? remote.origin : undefined
      if (!expectedOrigin || (req.headers.origin && req.headers.origin !== expectedOrigin)) {
        return json(403, { error: "Use the printed loopback URL or the configured SANDBOX_URL with its startup token." })
      }
      const url = new URL(req.url, origin)
      const path = url.pathname
      const loopback = expectedOrigin === origin && ["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(req.socket.remoteAddress)
      if (!loopback) {
        const cookie = req.headers.cookie?.split(";").map((part) => part.trim()).find((part) => part.startsWith("p3stack_sandbox="))?.slice("p3stack_sandbox=".length)
        if (remote && req.method === "GET" && path === "/" && validToken(url.searchParams.get("token"))) {
          res.setHeader("Set-Cookie", `p3stack_sandbox=${token}; HttpOnly; Secure; SameSite=Strict; Path=/`)
          url.searchParams.delete("token")
          res.writeHead(302, { Location: `${path}${url.search}` })
          return res.end()
        }
        if (!remote || !validToken(cookie)) return json(403, { error: "Open the SANDBOX_URL link printed at startup to set its access cookie." })
      }
      if (req.method === "GET" && assets.has(path)) {
        const [file, type] = assets.get(path)
        const content = await readFile(new URL(file, import.meta.url))
        res.writeHead(200, { "Content-Type": type })
        return res.end(content)
      }
      if (req.method === "GET" && path === "/scenarios") return json(200, scenarios)
      if (req.method === "POST" && path === "/sessions") {
        const key = req.socket.remoteAddress
        const recent = (attempts.get(key) || []).filter((time) => Date.now() - time < rateWindowMs)
        attempts.set(key, recent)
        if (recent.length >= createLimit) {
          res.setHeader("Retry-After", String(Math.ceil(rateWindowMs / 1000)))
          return json(429, { error: "Too many session requests. Try again in a minute." })
        }
        recent.push(Date.now())
        const { scenario: name } = await body(req)
        const scenario = scenarios.find((item) => item.id === name)
        if (!scenario) return json(400, { error: "Unknown scenario" })
        if (sessions.size >= 8) return json(429, { error: "Eight sessions are already open. Close or reset a terminal first." })
        const id = randomUUID()
        const dir = join(root, id)
        const session = { dir }
        sessions.set(id, session)
        const preparation = (async () => { await mkdir(dir); await prepare(dir, scenario) })()
        preparing.add(preparation)
        try { await preparation } catch (error) { close(id); throw error } finally { preparing.delete(preparation) }
        if (!sessions.has(id)) return json(410, { error: "Session closed during setup" })
        touch(id)
        return json(201, { id, scratch: `${dir}/work` })
      }
      const match = path.match(/^\/sessions\/([a-f0-9-]+)(\/events|\/input|\/resize)?$/)
      const session = match && sessions.get(match[1])
      if (!session) return json(404, { error: "Session not found" })
      const id = match[1]
      if (req.method === "DELETE" && !match[2]) {
        close(id)
        return json(200, {})
      }
      if (req.method === "GET" && match[2] === "/events" && !session.terminal) {
        touch(id)
        res.writeHead(200, { "Content-Type": "text/event-stream", "Connection": "keep-alive" })
        res.flushHeaders()
        session.stream = res
        session.terminal = pty.spawn("bwrap", [...isolation(session.dir), "/bin/bash", "--noprofile", "--rcfile", "/sandbox/shell.rc", "-i"], {
          name: "xterm-256color", cols: 100, rows: 32, cwd: session.dir, env: {},
        })
        session.terminal.onData((data) => {
          if (sessions.has(id) && !res.writableEnded && !res.destroyed) { touch(id); res.write(`data: ${JSON.stringify(data)}\n\n`) }
        })
        session.terminal.onExit(({ exitCode }) => {
          if (!res.writableEnded && !res.destroyed) res.write(`event: exit\ndata: ${exitCode}\n\n`)
          close(id, true)
          void rm(session.dir, { recursive: true, force: true })
        })
        res.on("close", () => close(id))
        return
      }
      if (req.method === "POST" && session.terminal) {
        const value = await body(req)
        if (match[2] === "/input" && typeof value.data === "string") { touch(id); session.terminal.write(value.data) }
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

  try {
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(port, "127.0.0.1", resolve) })
  } catch (error) { await rm(root, { recursive: true, force: true }); throw error }
  origin = `http://127.0.0.1:${server.address().port}`
  const remoteUrl = remote ? `${remote.origin}/?token=${token}` : undefined
  log(`Update sandbox: ${origin}\n${remoteUrl ? `Tailnet access: ${remoteUrl}\n` : ""}Scratch: ${root}\nRequires Linux, Bubblewrap, and unprivileged user namespaces. Ctrl-C stops all terminals.`)
  return {
    origin,
    async stop() {
      for (const id of sessions.keys()) close(id)
      const closed = new Promise((resolve) => server.close(resolve))
      server.closeAllConnections()
      await Promise.allSettled([...preparing])
      await closed
      await rm(root, { recursive: true, force: true })
    },
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const sandbox = await startSandbox()
    for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, async () => { await sandbox.stop(); process.exit(0) })
  } catch (error) { console.error(error.message); process.exitCode = 1 }
}
