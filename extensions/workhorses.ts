// ABOUTME: pi extension: puts the workhorse policy, which Claude Code and Codex get from the SessionStart hook,
// ABOUTME: into pi's system prompt as a section, so pi knows the hosts and how to run wh.
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const policyScript = join(dirname(dirname(fileURLToPath(import.meta.url))), "scripts", "policy.sh");

// The policy is read once per session, as the hook does, and set again before every run, since a section
// added once would not outlive compaction.
export default function (pi: ExtensionAPI) {
  let policy: string | undefined;
  pi.on("session_start", () => {
    policy = undefined;
  });
  pi.on("before_agent_start", (event) => {
    policy ??= readPolicy();
    event.systemPromptOptions.sections["claude-workhorses"] = policy;
  });
}

// A failing script must not stop the session, so its error becomes the section, where the model can report it.
function readPolicy(): string {
  try {
    return execFileSync("bash", [policyScript], { encoding: "utf8", timeout: 10_000 });
  } catch (error) {
    return `claude-workhorses: ${policyScript} failed, so the workhorse policy is missing: ${(error as Error).message}`;
  }
}
