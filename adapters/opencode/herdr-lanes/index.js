// OpenCode plugin: holds a herdr-spawn lane or coordinator to its role. OpenCode has no goal or blocking stop
// hook, so after each finished run of a root session it asks lane-stop-check.sh, the check every harness shares,
// and prompts the session with its reason when it may not stop yet. The check caps itself at three prompts in a
// row. Subagent sessions are skipped: the role belongs to the session in the pane. spawn.sh's OpenCode lane
// template loads this directory through OPENCODE_CONFIG; list it under `plugins` in your own config to cover
// coordinators too.
import { execFile } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const check = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../../skills/herdr-spawn/scripts/lane-stop-check.sh");

function reason() {
  return new Promise((resolve) =>
    execFile(check, { timeout: 10_000 }, (error, stdout) => resolve(error ? "" : stdout.trim())),
  );
}

export default {
  id: "herdr-lanes",
  async setup(ctx) {
    const controller = new AbortController();
    const children = new Set();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (event.type === "session.created" && event.data.parentID) children.add(event.data.sessionID);
          if (event.type !== "session.execution.succeeded" || children.has(event.data.sessionID)) continue;
          const text = await reason();
          if (!text) continue;
          try {
            await ctx.session.prompt({ sessionID: event.data.sessionID, text });
          } catch (error) {
            console.error("[herdr-lanes] prompt failed", error);
          }
        }
      } catch (error) {
        if (!controller.signal.aborted) console.error("[herdr-lanes] event subscription failed", error);
      }
    })();
    return () => controller.abort();
  },
};
