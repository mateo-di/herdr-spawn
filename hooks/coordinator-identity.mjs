// A Claude Code session that starts a lane is a coordinator, and only the session itself can set its name and
// prompt-bar color. spawn.sh leaves a request under its state directory, keyed by the session ID; once the
// session is idle this module runs /rename and /color for whichever the session does not have yet.

const chunk = 4 * 1024 * 1024
const colors = ['red', 'blue', 'green', 'yellow', 'purple', 'orange', 'pink', 'cyan']

// Which of the two the transcript records. Each row starts its own line, so text quoted in a message never
// counts, and a title Claude Code generates on its own has another row type.
async function recorded($, path) {
  const found = { name: false, color: false }
  const rows = { name: '\n{"type":"custom-title"', color: '\n{"type":"agent-color"' }
  const { size } = await $.fs.stat(path)
  // Consecutive reads overlap by more than a marker, so one cut by a boundary is still seen.
  for (let offset = 0; offset < size; offset += chunk - 256) {
    const read = await $.fs.read(path, { offset, length: chunk })
    const text = offset === 0 ? `\n${read}` : read
    for (const key of Object.keys(rows)) found[key] ||= text.includes(rows[key])
    if (found.name && found.color) break
  }
  return found
}

// The commands that would fill what the session does not have yet.
async function missingFrom($, request) {
  // An unreadable transcript rejects here: what cannot be checked is not set.
  const has = await recorded($, (await $.session.info()).transcriptPath)
  const missing = []
  if (!has.name && /^coord-[A-Za-z0-9._-]+$/.test(request.name)) missing.push({ command: 'rename', args: request.name })
  if (!has.color && colors.includes(request.color)) missing.push({ command: 'color', args: request.color })
  return missing
}

async function apply($, turn) {
  const id = await $.session.id()
  const state = (await $.env.get('XDG_STATE_HOME')) || `${await $.env.get('HOME')}/.local/state`
  const path = `${state}/herdr-spawn/identity/${id}.json`
  if (!(await $.fs.exists(path))) return
  const request = JSON.parse(await $.fs.read(path))
  if (request.sessionId !== id || request.done) return
  // A -p run draws nowhere; it may be a second process on a session someone has open.
  if (!(await $.session.surfaces()).length) return
  for (;;) {
    // A fresh look before each command: the user can set either one at any moment.
    const missing = await missingFrom($, request)
    // /clear or /resume can switch sessions meanwhile: what was just read, and what runs next, must be this one's.
    if ((await $.session.id()) !== id) return
    if (!missing.length) break
    // Once per session, so a command Claude Code refuses is not repeated after every turn.
    const call = missing.find(({ command }) => !turn.asked.has(`${id} ${command}`))
    // A refusal is not an error, so only the transcript tells. Until it records both, the request stays pending and
    // spawn.sh keeps telling the user. A turn that started meanwhile leaves the rest for after it.
    if (!call || turn.running) return
    await $.command.run(call)
    turn.asked.add(`${id} ${call.command}`)
  }
  await $.fs.write(path, `${JSON.stringify({ ...request, done: true })}\n`)
}

// Runs outside the event's own hook, which a command may not run inside.
function whenIdle($, turn) {
  $.clock.after(1000, async () => {
    if (turn.running || turn.applying) return
    turn.applying = true
    try {
      await apply($, turn)
    } catch (error) {
      $.ui.log(`herdr-spawn: could not set the coordinator identity: ${error.message}`, { to: 'debug' })
    } finally {
      turn.applying = false
    }
  })
}

export function register(on) {
  const turn = { running: false, applying: false, asked: new Set() }

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    whenIdle($, turn)
    return result
  })

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) turn.running = true
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      turn.running = false
      whenIdle($, turn)
    }
    return result
  })
}
