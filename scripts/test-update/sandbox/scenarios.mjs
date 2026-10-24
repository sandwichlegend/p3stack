export const scenarios = [
  { id: "clean", description: "No local edits in any of the four tools.", try: "Run p3stack update, then press Enter to update every tool." },
  { id: "kept", description: "Your marked skill edit has no upstream change.", try: "Update. Your edit should stay without a question." },
  { id: "copy", description: "Claude has your edit; Codex has the original.", try: "Update, pick Y to copy, then update again." },
  { id: "both", description: "You and the release changed the same skill.", try: "Pick K, then Y, then update again. Reset to try A or T, then agent 1." },
  { id: "hand", description: "A skill was edited without an edited mark.", try: "Update. Check that the edit stays and gains edited: true." },
  { id: "nobody", description: "Both sides changed, with nobody at the keyboard.", try: "Update. Noninteractive mode keeps your edit without a merge prompt.", env: "export P3STACK_NONINTERACTIVE=1" },
  { id: "removed", description: "The release removed a skill you edited.", try: "Pick K to move it to ~/.agents/skills. Reset and try A." },
  { id: "first", description: "Old installs have no saved installation record.", try: "Update, then pick A at the Codex question. Inspect the saved copies." },
  { id: "script", description: "You and the release changed a skill's script.", try: "Pick T, then agent 1. Inspect the merged github.ts." },
]
