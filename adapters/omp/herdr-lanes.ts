// oh-my-pi extension: holds a herdr-spawn lane or coordinator to its role. When the session is about to stop,
// it asks lane-stop-check.sh, the check every harness shares, and continues the session with its reason when
// it may not stop yet. Load it with `omp -e <this file>` (spawn.sh's lane template does) or from
// ~/.omp/agent/extensions/ to cover coordinators too.
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const check = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../skills/herdr-spawn/scripts/lane-stop-check.sh");

function reason(): string {
  try {
    return execFileSync(check, { encoding: "utf8", timeout: 10_000 }).trim();
  } catch {
    return "";
  }
}

export default function (pi: any) {
  pi.on("session_stop", () => {
    const text = reason();
    if (text) return { continue: true, additionalContext: text };
  });
}
