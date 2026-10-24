import { execFile, spawnSync } from "node:child_process"
import { promisify } from "node:util"
import { mkdir, writeFile, symlink, readdir, unlink } from "node:fs/promises"
import { existsSync, readdirSync, realpathSync } from "node:fs"
import { fileURLToPath } from "node:url"

const exec = promisify(execFile)
const repo = fileURLToPath(new URL("../../../", import.meta.url))
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`

const utilities = `bash sh env git tar awk sed grep sha256sum shasum find sort diff cp mv rm mkdir cat ln ls head tail tr cut
  dirname basename mktemp touch chmod wc uname paste readlink sleep date python3 xargs tee stat realpath du less nano vim vi more clear which file cmp printf`.split(/\s+/)
const binaries = utilities.filter((name) => existsSync(`/usr/bin/${name}`))
const runtimeDirs = readdirSync("/usr/lib").filter((name) => /^(python3\.\d+|git-core|locale|gconv)$/.test(name))
const extensions = runtimeDirs.filter((name) => name.startsWith("python3.")).flatMap((name) => {
  const path = `/usr/lib/${name}/lib-dynload`
  return existsSync(path) ? readdirSync(path).filter((file) => file.endsWith(".so")).map((file) => `${path}/${file}`) : []
})
const linked = spawnSync("ldd", [...binaries.map((name) => realpathSync(`/usr/bin/${name}`)), process.execPath, ...extensions], { encoding: "utf8" })
if (linked.error) throw linked.error
const libraries = [...new Set([...linked.stdout.matchAll(/\/[^\s()]+/g)].map(([path]) => path).filter(existsSync))]

export function isolation(dir) {
  return [
    "--unshare-all", "--die-with-parent", "--clearenv",
    "--dir", "/usr/bin", "--dir", "/usr/lib",
    "--symlink", "usr/bin", "/bin", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64",
    ...binaries.flatMap((name) => ["--ro-bind", realpathSync(`/usr/bin/${name}`), `/usr/bin/${name}`]),
    ...libraries.flatMap((path) => ["--ro-bind", realpathSync(path), path]),
    ...runtimeDirs.flatMap((name) => ["--ro-bind", `/usr/lib/${name}`, `/usr/lib/${name}`]),
    ...["terminfo", "git-core", "nano", "file", "vim"].filter((name) => existsSync(`/usr/share/${name}`))
      .flatMap((name) => ["--ro-bind", `/usr/share/${name}`, `/usr/share/${name}`]),
    "--ro-bind", "/etc", "/etc", "--proc", "/proc", "--dev", "/dev",
    "--tmpfs", "/tmp", "--dir", "/runtime",
    "--ro-bind", process.execPath, "/runtime/node",
    "--ro-bind", repo, "/checkout", "--bind", dir, "/sandbox",
    "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/sandbox",
    "--setenv", "GIT_CONFIG_NOSYSTEM", "1", "--chdir", "/sandbox", "--remount-ro", "/",
  ]
}

export async function prepare(dir, scenario) {
  const { stdout } = await exec("bwrap", [...isolation(dir), "/bin/bash", "--noprofile", "--norc",
    "/checkout/scripts/test-update/fixtures.sh", scenario.id, "/sandbox/work"],
  { timeout: 30000, maxBuffer: 1024 * 1024 }).catch((error) => { throw new Error(error.stderr?.trim() || error.message) })
  const bin = `${dir}/work/bin`
  const installed = await readdir(bin)
  await mkdir(`${dir}/fixture-bin`)
  for (const tool of installed) {
    await unlink(`${bin}/${tool}`)
    await symlink("/checkout/scripts/test-update/fake-tool", `${dir}/fixture-bin/${tool}`)
    await writeFile(`${bin}/${tool}`, `#!/bin/bash\ncase "$*" in\n  plugin\\ *|--version) exec /sandbox/fixture-bin/${tool} "$@" ;;\n  *) [[ -f BRIEF.md ]] || { echo "Fake agent: choose Talk to a model during p3stack update to merge files."; exit 0; }; exec /usr/bin/python3 /checkout/scripts/test-update/sandbox/merge-agent.py ;;\nesac\n`, { mode: 0o755 })
  }
  await writeFile(`${bin}/p3stack`, '#!/bin/bash\nexport P3STACK_HANDOFF=1\nexec /runtime/node /checkout/cli/bin/p3stack.mjs "$@"\n', { mode: 0o755 })
  for (const tool of binaries) {
    if (!existsSync(`${dir}/work/sys/${tool}`)) await symlink(`/usr/bin/${tool}`, `${dir}/work/sys/${tool}`)
  }
  await symlink("/runtime/node", `${dir}/work/sys/node`)
  await mkdir(`${dir}/work/tmp`)
  await writeFile(`${dir}/shell.rc`, `${stdout}\nexport TMPDIR=/sandbox/work/tmp XDG_CONFIG_HOME=/sandbox/work/home/.config XDG_DATA_HOME=/sandbox/work/home/.local/share\nexport TERM=xterm-256color EDITOR=nano VISUAL=nano HISTFILE=/sandbox/work/home/.bash_history\nexport PS1='sandbox:${scenario.id} \\w $ '\n${scenario.env || ""}\ncd /sandbox/work\nprintf '%s\\n' ${quote(`Scenario: ${scenario.id}`)} ${quote(scenario.description)} ${quote(scenario.try)} 'Type p3stack update. Press Enter at the tool picker.' 'HOME, releases, clone, and edits live under /sandbox/work.' 'Useful: ls -a "$HOME"; find "$HOME" -name SKILL.md' ''\n`)
}
