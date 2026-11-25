// ABOUTME: OpenCode plugin, at the root because OpenCode loads a local plugin folder from its server.js: registers the
// ABOUTME: workhorse skill and adds the policy that Claude Code and Codex get from SessionStart to each top-level session.
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const root = dirname(fileURLToPath(import.meta.url));
const skillPath = join(root, "skills", "workhorse", "SKILL.md");
const policyScript = join(root, "scripts", "policy.sh");

function readSkill() {
  const text = readFileSync(skillPath, "utf8");
  const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!match) throw new Error(`claude-workhorses: no frontmatter in ${skillPath}`);
  const field = (name) => match[1].match(new RegExp(`^${name}: (.*?)\r?$`, "m"))?.[1];
  return { id: "claude-workhorses-workhorse", name: field("name"), description: field("description"), path: skillPath, content: text.slice(match[0].length) };
}

// A failing script must not stop the session, so its error becomes the text, where the model can report it.
async function readPolicy() {
  try {
    return (await promisify(execFile)("bash", [policyScript], { timeout: 10_000 })).stdout;
  } catch (error) {
    return `claude-workhorses: ${policyScript} failed, so the workhorse policy is missing: ${error.message}`;
  }
}

export default {
  id: "claude-workhorses",
  async setup(ctx) {
    const skill = readSkill();
    await ctx.skill.transform((editor) => {
      if (!editor.get(skill.id)) editor.add(skill);
    });
    // The context hook runs before every request; the policy is read once per session, as the hook does. A
    // subagent's session has a parent and goes without, as SessionStart does not run for a Claude Code subagent.
    const policies = new Map();
    await ctx.session.hook("context", async (event) => {
      const session = await ctx.session.get({ sessionID: event.sessionID });
      if (session.parentID) return;
      if (!policies.has(event.sessionID)) policies.set(event.sessionID, readPolicy());
      event.system.push({ type: "text", text: await policies.get(event.sessionID) });
    });
  },
};
