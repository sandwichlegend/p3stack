const terminal = new window.Terminal({ cursorBlink: true, fontSize: 14, scrollback: 10000, theme: { background: "#10161d", foreground: "#dae4ed", cursor: "#81e6c1" } })
const fit = new window.FitAddon.FitAddon()
terminal.loadAddon(fit)
terminal.open(document.querySelector("#terminal"))
const status = document.querySelector("#status")
const reset = document.querySelector("#reset")
const cards = document.querySelector("#scenarios")
let current
let session
let events
let input = Promise.resolve()

async function request(path, method, value) {
  const response = await fetch(path, { method, headers: { "Content-Type": "application/json" }, body: value === undefined ? undefined : JSON.stringify(value) })
  const result = await response.json()
  if (!response.ok) throw new Error(result.error)
  return result
}

function resize() {
  fit.fit()
  if (session) void request(`/sessions/${session}/resize`, "POST", { cols: terminal.cols, rows: terminal.rows }).catch(showError)
}

function showError(error) {
  status.textContent = error.message
  status.dataset.error = "true"
}

async function load(scenario) {
  for (const button of document.querySelectorAll("button")) button.disabled = true
  current = scenario
  events?.close()
  const old = session
  session = undefined
  terminal.reset()
  status.dataset.error = "false"
  status.textContent = `Building ${scenario.id} from fixtures…`
  document.querySelector("#title").textContent = scenario.id
  document.querySelector("#hint").textContent = scenario.try
  for (const card of cards.children) card.setAttribute("aria-pressed", String(card.dataset.scenario === scenario.id))
  try {
    if (old) await request(`/sessions/${old}`, "DELETE").catch(() => {})
    const created = await request("/sessions", "POST", { scenario: scenario.id })
    session = created.id
    events = new EventSource(`/sessions/${session}/events`)
    events.onmessage = ({ data }) => terminal.write(JSON.parse(data))
    events.onopen = () => {
      status.textContent = `Scratch: ${created.scratch}`
      resize()
      terminal.focus()
    }
    events.addEventListener("exit", ({ data }) => {
      status.textContent = `Shell exited (${data}). Reset to start again.`
      events.close()
      session = undefined
    })
    events.onerror = () => {
      events.close()
      session = undefined
      showError(new Error("Terminal disconnected. Reset to start a fresh sandbox."))
    }
  } catch (error) {
    showError(error)
  } finally {
    for (const button of document.querySelectorAll("button")) button.disabled = false
  }
}

terminal.onData((data) => {
  const target = session
  if (target) input = input.then(() => request(`/sessions/${target}/input`, "POST", { data })).catch(showError)
})
reset.addEventListener("click", () => load(current))
new ResizeObserver(resize).observe(document.querySelector("#terminal"))
try {
  const scenarios = await request("/scenarios", "GET")
  for (const scenario of scenarios) {
    const button = document.createElement("button")
    button.dataset.scenario = scenario.id
    button.setAttribute("aria-pressed", "false")
    const name = document.createElement("strong")
    name.textContent = scenario.id
    const description = document.createElement("span")
    description.textContent = scenario.description
    const instruction = document.createElement("small")
    instruction.textContent = scenario.try
    button.append(name, description, instruction)
    button.addEventListener("click", () => load(scenario))
    cards.append(button)
  }
} catch (error) {
  showError(error)
}
