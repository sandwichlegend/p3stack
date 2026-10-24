import { execFileSync } from "node:child_process"
import assert from "node:assert/strict"
import { mkdtemp, mkdir, readFile, readdir, rm } from "node:fs/promises"
import { realpathSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"
import * as pty from "node-pty"
import { isolation, prepare } from "./sandbox.mjs"
import { scenarios } from "./scenarios.mjs"
import { verifyHttp } from "./verify-http.mjs"

const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`
const hidden = [homedir(), "/root", "/usr/lib/chatgpt/resources/codex", "/usr/bin/codex", "/usr/bin/claude"]
for (const name of ["claude", "codex", "cursor-agent", "opencode"]) {
  const paths = execFileSync("/bin/bash", ["-c", `type -ap ${name} || true`], { encoding: "utf8" }).trim().split("\n").filter(Boolean)
  hidden.push(...paths, ...paths.map((path) => realpathSync(path)))
}
const scratch = await mkdtemp(join(tmpdir(), "p3stack-sandbox-verify-"))
const answers = {
  copy: [["Choose Y/N", "y"]],
  both: [["Choose K/A/T", "t"], ["Choose 1/2", "1"], ["Choose Y/N", "y"]],
  removed: [["Choose K/A", "k"]],
  first: [["Choose K/A", "a"]],
  script: [["Choose K/A/T", "t"], ["Choose 1", "1"]],
  interrupted: [["Choose K/A/T", "k"]],
  "removed-file": [["Choose K/A", "a"], ["Choose K/A", "k"]],
  "auto-updated": [["Choose K/A/T", "k"]],
}
const expected = {
  clean: "No edited files.", kept: "Kept your version of poteto-mode.",
  copy: "Copied your poteto-mode from Claude Code", both: "Installed the merged poteto-mode",
  hand: "Marked it edited.", nobody: "No one is at the keyboard to choose",
  removed: "Moved your recall to ~/.agents/skills/recall", first: "Installed p3stack's versions.",
  script: "Installed the merged poteto-mode/scripts/watch-pr/github.ts",
  interrupted: "Finished an interrupted update",
  added: "Kept your file skills/poteto-mode/references/mine.md.",
  "removed-file": "Kept your version of recall/references/notes.md.",
  "auto-updated": "Kept your version of poteto-mode.",
  "stale-plugin": "No edited files.",
}
try {
  for (const scenario of scenarios) {
    const dir = join(scratch, scenario.id)
    await mkdir(dir)
    await prepare(dir, scenario)
    const installedTool = (await readdir(join(dir, "fixture-bin")))[0]
    const shell = pty.spawn("bwrap", [...isolation(dir), "/bin/bash", "--noprofile", "--rcfile", "/sandbox/shell.rc", "-i"], { cwd: dir, env: {}, cols: 120, rows: 40 })
    let output = ""
    shell.onData((data) => { output += data })
    const wait = async (text, since = 0) => {
      const deadline = Date.now() + 15000
      while (!output.slice(since).includes(text)) {
        assert(Date.now() < deadline, `${scenario.id}: missing ${text}\n${output}`)
        await new Promise((resolve) => setTimeout(resolve, 20))
      }
    }
    try {
      await wait("/sandbox/work $ ")
      let since = output.length
      shell.write("p3stack update; printf '\\nUPDATE_EXIT=%s\\n' \"$?\"\r")
      await wait("enter confirm", since)
      since = output.length
      shell.write("\r")
      for (const [prompt, answer] of answers[scenario.id] || []) {
        await wait(prompt, since)
        since = output.length
        shell.write(`${answer}\r`)
      }
      await wait("/sandbox/work $ ", since)
      if (scenario.id === "interrupted") {
        assert(output.includes("\r\nUPDATE_EXIT=1\r\n"), output)
        since = output.length
        shell.write("unset P3STACK_FAKE_FAIL_AFTER_UPDATE; p3stack update; printf '\\nUPDATE_EXIT=%s\\n' \"$?\"\r")
        await wait("enter confirm", since)
        since = output.length
        shell.write("\r")
        await wait("Choose K/A/T", since)
        since = output.length
        shell.write("k\r")
        await wait("/sandbox/work $ ", since)
      }
      assert(output.includes(expected[scenario.id]), output)
      assert(output.includes("\r\nUPDATE_EXIT=0\r\n"), output)
      if (scenario.id === "both" || scenario.id === "script") {
        const folder = scenario.id === "both" ? "poteto-mode/SKILL.md" : "poteto-mode/scripts/watch-pr/github.ts"
        const extension = scenario.id === "both" ? "md" : "ts"
        const merged = await readFile(`${dir}/work/home/.p3stack/merge/claude/p3stack/skills/${folder}/result.${extension}`, "utf8")
        assert(merged.includes(scenario.id === "both" ? "Write the code test first." : 'return [branch, "main"]'))
        assert(merged.includes(scenario.id === "both" ? "Pause before force-pushes." : "if (!branch) return []"))
      }
      since = output.length
      shell.write(`python3 -c 'import ctypes, pyexpat, sqlite3, ssl; print("PYTHON_OK")'; nano --version; file /etc/passwd\r`)
      await wait("/sandbox/work $ ", since)
      assert(output.slice(since).includes("\r\nPYTHON_OK\r\n"), output)
      assert(output.slice(since).includes("GNU nano"), output)
      assert(output.slice(since).includes("ASCII text"), output)
      since = output.length
      shell.write(`${hidden.map((path) => `test ! -e ${quote(path)}`).join(" && ")} && ! touch /checkout/.sandbox-write-probe && ! touch /usr/.sandbox-write-probe && ! touch /etc/.sandbox-write-probe && test "$HOME" = /sandbox/work/home && test "$(command -v ${installedTool})" = /sandbox/work/bin/${installedTool} && test "$(command -v nano)" = /sandbox/work/sys/nano && echo ISOLATION_OK\r`)
      await wait("/sandbox/work $ ", since)
      assert(output.slice(since).includes("\r\nISOLATION_OK\r\n"), output)
      console.log(`${scenario.id}: real CLI, expected result, isolation checks passed`)
    } finally {
      const exited = new Promise((resolve) => shell.onExit(resolve))
      shell.kill()
      await exited
    }
  }
} finally {
  await rm(scratch, { recursive: true, force: true })
}

await verifyHttp()
