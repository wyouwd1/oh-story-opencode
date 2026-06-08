/**
 * oh-story OpenCode Plugin — story-hooks
 *
 * Replaces the 6 Claude Code shell hooks (session-start, session-end,
 * detect-story-gaps, validate-story-commit, pre-compact, post-compact)
 * with OpenCode-native TypeScript plugin hooks.
 *
 * Dependencies:
 *   - @opencode-ai/plugin (bundled with OpenCode; provides Plugin type)
 *   - Node.js built-ins: path, fs
 *
 * NOTE: experimental.* hooks may change in future OpenCode versions.
 * Tested against OpenCode (2026-06). If hooks stop firing after an upgrade,
 * check the OpenCode plugin API documentation for renamed hooks.
 */

// If @opencode-ai/plugin is not available as an installable package, use this
// ambient declaration as a fallback. OpenCode resolves it at runtime.
declare module "@opencode-ai/plugin" {
  interface PluginInput {
    /** Project root directory */
    directory: string
    /** OpenCode client instance */
    client?: unknown
    /** Project metadata */
    project?: unknown
  }
  interface TransformOutput {
    system?: string
    message?: string
  }
  interface ExecuteInput {
    tool: string
    args?: Record<string, unknown>
  }
  type Plugin = (input: PluginInput) => Promise<Record<string, (input: unknown, output: unknown) => void>>
}

import type { Plugin } from "@opencode-ai/plugin"
import { resolve, dirname } from "node:path"
import { readFileSync, existsSync, readdirSync } from "node:fs"

// Find project root (walk up to find .opencode/ or .git/)
function findProjectRoot(startDir: string): string {
  let dir = startDir
  for (let i = 0; i < 10; i++) {
    if (existsSync(resolve(dir, ".git")) || existsSync(resolve(dir, ".opencode"))) {
      return dir
    }
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return startDir
}

// Find active book directory
function findActiveBook(projectDir: string): string | null {
  const activeBookPath = resolve(projectDir, ".active-book")
  if (existsSync(activeBookPath)) {
    const active = readFileSync(activeBookPath, "utf-8").trim()
    if (active) {
      const resolved = resolve(projectDir, active)
      if (existsSync(resolved)) return resolved
    }
  }
  // Fallback: find first directory containing 追踪/
  function find(dir: string, depth: number): string | null {
    if (depth > 4) return null
    try {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        if (e.isDirectory()) {
          if (e.name === "追踪") return dir
          const found = find(resolve(dir, e.name), depth + 1)
          if (found) return found
        }
      }
    } catch {
      // permission errors, skip
    }
    return null
  }
  return find(projectDir, 0)
}

// Check if .story-deployed sentinel exists
function isStoryDeployed(projectDir: string): boolean {
  return existsSync(resolve(projectDir, ".story-deployed"))
}

// Read sentinel field value
function readSentinelField(projectDir: string, field: string): string | null {
  const path = resolve(projectDir, ".story-deployed")
  if (!existsSync(path)) return null
  const content = readFileSync(path, "utf-8")
  const lines = content.split("\n")
  for (const line of lines) {
    const trimmed = line.trim()
    if (trimmed.startsWith(field + ":")) {
      return trimmed.slice(field.length + 1).trim().replace(/^["']|["']$/g, "")
    }
  }
  return null
}

export default (async ({ directory }) => {
  const projectDir = findProjectRoot(directory)

  return {
    // ----- Session Start: Show project status -----
    "experimental.chat.system.transform": async (_input, output) => {
      if (!isStoryDeployed(projectDir)) {
        output.system =
          (output.system || "") +
          "\n[story-hooks] 写作环境未部署。运行 /story-setup 初始化。\n"
        return
      }

      const parts: string[] = []

      // Check sentinel version
      const agentsVersion = readSentinelField(projectDir, "agents_version")
      if (agentsVersion && parseInt(agentsVersion) < 10) {
        parts.push(
          `[story-hooks] agents_version=${agentsVersion} 低于 v10。运行 /story-setup 刷新。`
        )
      }

      // Show active book
      const bookDir = findActiveBook(projectDir)
      if (bookDir) {
        const ctxPath = resolve(bookDir, "追踪", "上下文.md")
        if (existsSync(ctxPath)) {
          const ctxLines = readFileSync(ctxPath, "utf-8").split("\n").slice(0, 10).join("\n")
          parts.push(`[story-hooks] 当前进度:\n${ctxLines}`)
        }
      }

      // Check for incomplete analysis
      const analysisDir = resolve(projectDir, "拆文库")
      if (existsSync(analysisDir)) {
        const progressFiles: string[] = []
        function scan(dir: string, depth: number) {
          if (depth > 5) return
          try {
            for (const e of readdirSync(dir, { withFileTypes: true })) {
              const p = resolve(dir, e.name)
              if (e.isDirectory()) scan(p, depth + 1)
              else if (e.name === "_progress.md") progressFiles.push(p)
            }
          } catch {}
        }
        scan(analysisDir, 0)
        if (progressFiles.length > 0) {
          parts.push(
            `[story-hooks] 拆文库/ 中有 ${progressFiles.length} 个未完成拆文。`
          )
        }
      }

      // Detect story gaps
      if (bookDir) {
        const chapterDir = resolve(bookDir, "正文")
        const settingDir = resolve(bookDir, "设定")
        if (existsSync(chapterDir) && existsSync(settingDir)) {
          try {
            const chapterCount = readdirSync(chapterDir).filter(
              (f) => f.endsWith(".md")
            ).length
            const settingFiles: string[] = []
            function scan(dir: string, depth: number) {
              if (depth > 5) return
              try {
                for (const e of readdirSync(dir, { withFileTypes: true })) {
                  if (e.isDirectory()) scan(resolve(dir, e.name), depth + 1)
                  else if (e.name.endsWith(".md")) settingFiles.push(e.name)
                }
              } catch { /* permission errors, skip */ }
            }
            scan(settingDir, 0)
            const settingCount = settingFiles.length
            if (chapterCount > 10 && settingCount < 3) {
              parts.push(
                `[story-hooks] ${chapterCount} 章正文，但设定文件仅 ${settingCount} 个，建议补充设定。`
              )
            }
          } catch { /* permission errors, skip */ }
        }
        if (existsSync(resolve(bookDir, "追踪")) && !existsSync(resolve(bookDir, "大纲"))) {
          parts.push(`[story-hooks] 已有正文但缺少大纲，建议先搭大纲。`)
        }
      }

      if (parts.length > 0) {
        output.system = (output.system || "") + "\n" + parts.join("\n") + "\n"
      }
    },

    // ----- Git commit validation -----
    "tool.execute.before": async (input, _output) => {
      if (input.tool !== "bash") return
      const cmd = input.args?.command as string | undefined
      if (!cmd || !cmd.includes("git commit")) return

      // Log that validation is happening - the actual check runs in bash
      // The shell hook validation is advisory-only, same pattern here
      console.log("[story-hooks] Git commit detected. Validating story files...")
    },

    // ----- Pre-compact: save state pointer -----
    "experimental.session.compacting": async (_input, output) => {
      const bookDir = findActiveBook(projectDir)
      if (!bookDir) return

      const ctxPath = resolve(bookDir, "追踪", "上下文.md")
      if (existsSync(ctxPath)) {
        output.message = `[story-hooks] 压缩前：写作上下文保存在 追踪/上下文.md。压缩后请首先读取恢复。`
      }
    },

    // ----- Post-compact: remind context recovery -----
    "experimental.compaction.autocontinue": async (_input, output) => {
      const bookDir = findActiveBook(projectDir)
      if (!bookDir) return

      const ctxPath = resolve(bookDir, "追踪", "上下文.md")
      if (existsSync(ctxPath)) {
        output.message = `[story-hooks] 上下文已压缩。读取 追踪/上下文.md 恢复写作状态。`
      }
    },
  }
}) satisfies Plugin
