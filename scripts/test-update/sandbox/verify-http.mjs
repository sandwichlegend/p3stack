import assert from "node:assert/strict"
import http from "node:http"
import { spawnSync } from "node:child_process"
import { setTimeout as delay } from "node:timers/promises"
import { startSandbox } from "./server.mjs"

function rawRequest(origin, path, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(new URL(path, origin), { method, headers }, (res) => {
      const chunks = []
      res.on("data", (chunk) => chunks.push(chunk))
      res.on("end", () => resolve({ status: res.statusCode, headers: new Headers(res.headers),
        json: async () => JSON.parse(Buffer.concat(chunks).toString()) }))
    })
    req.on("error", reject)
    req.end(body)
  })
}

export async function verifyHttp() {
  for (const value of ["bad-url", "https://user:pass@host.ts.net", "https://host.ts.net/path", "https://host.ts.net/?q=1", "https://host.ts.net/#x", "http://host.ts.net"]) {
    const result = spawnSync(process.execPath, [new URL("server.mjs", import.meta.url).pathname], {
      env: { ...process.env, SANDBOX_URL: value }, encoding: "utf8",
    })
    assert.equal(result.status, 1, value)
    assert.match(result.stderr, /SANDBOX_URL must/)
    assert(!result.stderr.includes("\n    at "), result.stderr)
  }

  const logs = []
  const sandbox = await startSandbox({ port: 0, sandboxUrl: "https://fixture.tailnet.ts.net", log: (line) => logs.push(line) })
  const request = (path, options = {}) => rawRequest(sandbox.origin, path, options)
  try {
    const link = logs.join("\n").match(/https:\/\/fixture\.tailnet\.ts\.net\/\?token=([^\s]+)/)[0]
    const token = new URL(link).searchParams.get("token")
    assert.equal(logs.length, 1)
    const spoofed = { Host: new URL(sandbox.origin).host }
    for (const path of ["/", "/scenarios", "/client.mjs"]) {
      assert.equal((await request(path, { headers: spoofed })).status, 403, `loopback ${path} without a token`)
    }
    assert.equal((await request("/sessions", { method: "POST", headers: spoofed, body: '{"scenario":"clean"}' })).status, 403)
    assert(logs[0].includes(`${sandbox.origin}/?token=${token}`), "startup prints the loopback link with its token")
    assert.equal(logs[0].split(token).length, 3, "startup prints the token only in its two links")
    const local = await request(`/?token=${token}&keep=yes`)
    assert.equal(local.status, 302)
    const localCookie = local.headers.get("set-cookie")
    assert(!localCookie.includes("Secure"), "the loopback cookie works over plain HTTP")
    const signedIn = { Cookie: localCookie.split(";")[0] }
    assert.equal((await request("/?query=works", { headers: signedIn })).status, 200)
    assert.equal((await request("/scenarios?query=works", { headers: signedIn })).status, 200)
    for (const headers of [
      { Host: "evil.invalid" }, { Host: "fixture.tailnet.ts.net.evil.invalid" },
      { Origin: "https://evil.invalid" }, { Origin: "https://fixture.tailnet.ts.net" },
      { Host: "fixture.tailnet.ts.net", Origin: sandbox.origin },
    ]) assert.equal((await request("/scenarios", { headers })).status, 403)
    const remote = { Host: "fixture.tailnet.ts.net", Origin: "https://fixture.tailnet.ts.net" }
    for (const path of ["/", "/client.mjs", "/scenarios", "/sessions/missing/events", `/scenarios?token=${token}`]) {
      assert.equal((await request(path, { headers: remote })).status, 403, path)
    }
    assert.equal((await request("/sessions", { method: "POST", headers: remote, body: '{"scenario":"clean"}' })).status, 403)
    for (const cookie of ["p3stack_sandbox=wrong", `p3stack_sandbox=${"x".repeat(token.length)}`]) {
      assert.equal((await request("/scenarios", { headers: { ...remote, Cookie: cookie } })).status, 403)
    }
    assert.equal((await request("/?token=wrong", { headers: remote })).status, 403)
    const bootstrap = await request(`/?token=${token}&keep=yes`, { headers: remote })
    assert.equal(bootstrap.status, 302)
    assert.equal(bootstrap.headers.get("location"), "/?keep=yes")
    const cookie = bootstrap.headers.get("set-cookie")
    for (const flag of ["HttpOnly", "Secure", "SameSite=Strict", "Path=/"]) assert(cookie.includes(flag))
    const authenticated = { ...remote, Cookie: cookie.split(";")[0] }
    assert.equal((await request("/scenarios?query=works", { headers: authenticated })).status, 200)
    const remoteSession = await request("/sessions?query=works", { method: "POST", headers: authenticated, body: '{"scenario":"clean"}' })
    assert.equal(remoteSession.status, 201)
    const remoteId = (await remoteSession.json()).id
    assert.equal((await request(`/sessions/${remoteId}`, { method: "DELETE", headers: remote })).status, 403)
    assert.equal((await request(`/sessions/${remoteId}?query=works`, { method: "DELETE", headers: authenticated })).status, 200)
    const results = await Promise.all(Array.from({ length: 10 }, () => request("/sessions", {
      method: "POST", headers: signedIn, body: '{"scenario":"clean"}',
    })))
    assert.equal(results.filter((res) => res.status === 201).length, 8, "cap includes preparations in flight")
    assert.equal(results.filter((res) => res.status === 429).length, 2)
    for (const res of results.filter((res) => res.status === 201)) {
      const { id } = await res.json()
      assert.equal((await request(`/sessions/${id}`, { method: "DELETE", headers: signedIn })).status, 200)
    }
  } finally { await sandbox.stop() }

  const rate = await startSandbox({ port: 0, sandboxUrl: "", createLimit: 2, rateWindowMs: 1000, log() {} })
  try {
    const create = (body) => fetch(`${rate.origin}/sessions`, { method: "POST", body })
    for (const body of ['{"scenario":"unknown"}', '{"scenario":"unknown"}', '{"scenario":"unknown"}', "not json", "null", "[]"]) {
      assert.equal((await create(body)).status, 400, `${body} is rejected without counting against the limit`)
    }
    const burst = await Promise.all([1, 2, 3].map(() => create('{"scenario":"clean"}')))
    assert.deepEqual(burst.map((res) => res.status).sort(), [201, 201, 429])
    assert(burst.find((res) => res.status === 429).headers.has("retry-after"))
    await delay(1100)
    const later = await create('{"scenario":"clean"}')
    assert.equal(later.status, 201, "the window frees up")
    for (const res of [...burst, later].filter((res) => res.status === 201)) {
      const { id } = await res.json()
      assert.equal((await fetch(`${rate.origin}/sessions/${id}`, { method: "DELETE" })).status, 200)
    }
    assert.equal((await rawRequest(rate.origin, "/", { headers: { Host: "fixture.tailnet.ts.net" } })).status, 403)
  } finally { await rate.stop() }

  const idle = await startSandbox({ port: 0, sandboxUrl: "", idleMs: 1500, log() {} })
  const abort = new AbortController()
  try {
    const created = await fetch(`${idle.origin}/sessions`, { method: "POST", body: '{"scenario":"clean"}' })
    const { id } = await created.json()
    const stream = await fetch(`${idle.origin}/sessions/${id}/events`, { signal: abort.signal })
    let output = ""
    const reading = (async () => {
      let buffer = ""
      for await (const chunk of stream.body) {
        buffer += Buffer.from(chunk).toString()
        let end
        while ((end = buffer.indexOf("\n\n")) >= 0) {
          const frame = buffer.slice(0, end)
          buffer = buffer.slice(end + 2)
          const data = frame.split("\n").find((line) => line.startsWith("data: "))?.slice(6)
          if (data) { const value = JSON.parse(data); if (typeof value === "string") output += value }
        }
      }
    })().catch((error) => { if (error.name !== "AbortError") throw error })
    const wait = async (text) => {
      const deadline = Date.now() + 5000
      while (!output.includes(text)) { assert(Date.now() < deadline, output); await delay(20) }
    }
    await wait("/tmp/sandbox/work $ ")
    const input = (data) => fetch(`${idle.origin}/sessions/${id}/input`, { method: "POST", body: JSON.stringify({ data }) })
    assert.equal((await input("for i in 1 2 3 4 5 6 7 8; do echo OUTPUT_ALIVE; sleep 0.3; done\r")).status, 200)
    await wait("OUTPUT_ALIVE\r\n".repeat(8))
    await delay(300)
    assert.equal((await input("echo INPUT_ALIVE\r")).status, 200, "output refreshes idle expiry")
    await wait("INPUT_ALIVE\r\n")
    await delay(700)
    assert.equal((await input("\r")).status, 200, "input refreshes idle expiry")
    await delay(2500)
    assert.equal((await fetch(`${idle.origin}/sessions/${id}`, { method: "DELETE" })).status, 404, "idle shell expires")
    await reading
  } finally { abort.abort(); await idle.stop() }
  console.log("HTTP: Host, Origin, token on every request, cookie, query routes, concurrent cap, rate limit, request bodies, and idle activity passed")
}
