/**
 * codegraph-index-reminder
 * Reminds the agent to get a CodeGraph index running before structural work.
 *
 * Claude Code and Codex run the shared `codegraph-session-reminder` script from
 * a native SessionStart hook. OpenCode has no session hook, so this plugin
 * injects the same reminder as a synthetic text part on the first message of
 * each session.
 *
 * CodeGraph's own `codegraph prompt-hook` stays silent on an unindexed project
 * (empty stdout, exit 0), so nothing otherwise reports a missing index.
 */

import type { Plugin } from "@opencode-ai/plugin"
import { execFile } from "child_process"
import { access } from "fs/promises"
import { homedir } from "os"
import { join, parse } from "path"
import { promisify } from "util"

const execFileAsync = promisify(execFile)

const REMINDER_SCRIPT = join(homedir(), ".local", "bin", "codegraph-session-reminder")

// Reminding outside a project is noise, so the plugin only speaks up where a
// CodeGraph index would actually be worth building. Mirrors the script's list.
const PROJECT_MARKERS = [
  ".git", ".hg", ".svn", "package.json", "go.mod", "Cargo.toml", "pyproject.toml",
  "pom.xml", "build.gradle", "composer.json", "Gemfile", "mix.exs", "deno.json",
]

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

async function isProjectRoot(cwd: string): Promise<boolean> {
  if (!cwd) return false
  if (cwd === parse(cwd).root) return false
  if (cwd === homedir()) return false
  for (const marker of PROJECT_MARKERS) if (await pathExists(join(cwd, marker))) return true
  return false
}

export const CodeGraphIndexReminderPlugin: Plugin = async (input) => {
  // One reminder per session: repeating it on every turn would burn context to
  // say something the agent already read.
  const reminded = new Set<string>()

  async function reminderText(cwd: string): Promise<string | undefined> {
    if (!(await isProjectRoot(cwd))) return undefined
    if (await pathExists(join(cwd, ".codegraph"))) return undefined
    if (!(await pathExists(REMINDER_SCRIPT))) return undefined
    try {
      const { stdout } = await execFileAsync(REMINDER_SCRIPT, ["--cwd", cwd], {
        cwd,
        timeout: 5_000,
      })
      const text = String(stdout).trim()
      return text.length > 0 ? text : undefined
    } catch (err) {
      // A startup reminder must never break a session.
      console.error("[codegraph-index-reminder] reminder failed:", err)
      return undefined
    }
  }

  return {
    "chat.message": async ({ sessionID }, output) => {
      if (!sessionID || reminded.has(sessionID)) return
      reminded.add(sessionID)

      const cwd = input.worktree || input.directory || process.cwd()
      const text = await reminderText(cwd)
      if (!text) return

      // Reuse the ids of an existing part: a synthetic part must belong to the
      // same message, and there is no id generator exposed to plugins.
      const anchor = output.parts.find((p) => p.type === "text")
      if (!anchor) return

      output.parts.push({
        ...anchor,
        id: `${anchor.id}-codegraph-reminder`,
        type: "text",
        text,
        synthetic: true,
      })
    },
  }
}

export default CodeGraphIndexReminderPlugin
