import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

const repo = join(import.meta.dir, "..")
const p3stackRoot = join(repo, "p3stack")
const skillSources = ["p3stack/skills", "team-kit/skills"]

function readSkill(dir: string, id: string) {
  const path = join(dir, id, "SKILL.md")
  const text = readFileSync(path, "utf8")
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text)
  if (!frontmatter) throw new Error(`p3stack: ${path} has no frontmatter`)
  const meta = Bun.YAML.parse(frontmatter[1]) as Record<string, unknown>
  return {
    id,
    name: typeof meta.name === "string" ? meta.name : id,
    description: typeof meta.description === "string" ? meta.description : undefined,
    autoinvoke: meta["disable-model-invocation"] !== true,
    path,
    content: text.slice(frontmatter[0].length),
  }
}

export default {
  id: "p3stack",
  async setup(ctx: any) {
    const skills = skillSources.flatMap((source) => {
      const dir = join(repo, source)
      return readdirSync(dir, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => readSkill(dir, entry.name))
    })
    const context = readFileSync(join(p3stackRoot, "hooks/session-start-context.md"), "utf8")
      .replaceAll("@P3STACK_ROOT@", p3stackRoot)
      .trimEnd()

    await ctx.skill.transform((editor: any) => {
      for (const skill of skills) editor.add(skill)
    })
    await ctx.session.hook("context", (event: any) => {
      event.system.push({ type: "text", text: context })
    })
  },
}
