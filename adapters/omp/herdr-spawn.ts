// oh-my-pi extension: gives the session spawn.sh starts the child's name, from HERDR_SPAWN_SESSION_NAME.
// Load it with `omp -e <this file>` (spawn.sh's omp templates do).
import { existsSync } from "node:fs";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  // Keep this extension eager: a deferred session_start can run after --goal is activated.
  pi.registerMessageRenderer("herdr-spawn-session-name", () => undefined);

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.agent.kind !== "main") return;
    const name = process.env.HERDR_SPAWN_SESSION_NAME;
    if (!name) return;
    // Consume the launch name so an extension reload cannot apply it to a different session.
    delete process.env.HERDR_SPAWN_SESSION_NAME;

    // A saved session is an older one being reopened: it keeps its name.
    const file = ctx.sessionManager.getSessionFile();
    if (file && existsSync(file)) return;
    try {
      await pi.setSessionName(name);
    } catch (error) {
      ctx.ui.notify(`herdr-spawn: could not name this session ${name}: ${error}`, "warning");
    }
  });
}
