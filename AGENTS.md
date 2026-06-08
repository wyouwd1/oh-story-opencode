# oh-story — 网文写作工具集 (OpenCode 适配)

## 语言规则

除专业术语（如 API、JSON、git、CLI、CDP、hook、Agent、Skill 等）外，所有输出必须使用简体中文。

## Skill 路由表

| 命令 | Skill | 说明 |
|------|-------|------|
| `/story-long-write`、`/写长篇` | story-long-write | 长篇网文写作（逐章推进） |
| `/story-short-write`、`/写短篇` | story-short-write | 短篇网文写作（情绪驱动） |
| `/story-long-analyze`、`/长篇拆文` | story-long-analyze | 长篇小说深度拆解 |
| `/story-short-analyze`、`/短篇拆文` | story-short-analyze | 短篇小说拆文分析 |
| `/story-long-scan`、`/长篇扫描` | story-long-scan | 长篇小说批量扫描 |
| `/story-short-scan`、`/短篇扫描` | story-short-scan | 短篇小说批量扫描 |
| `/story-deslop`、`/去AI味` | story-deslop | 去除 AI 写作痕迹 |
| `/story-cover`、`/封面` | story-cover | 生成封面图 |
| `/story-review`、`/审查` | story-review | 多视角对抗式审查 |
| `/story-import`、`/导入` | story-import | 逆向导入已有小说到项目结构 |
| `/story`、`/网文` | story | 工具箱路由 · 模糊意图自动分发 |
| `/story-setup`、`/准备写书` | story-setup | 环境部署 · agents/rules 一键部署 |
| `/browser-cdp` | browser-cdp | 浏览器 CDP 工具 |

## 文件结构

- `拆文库/` — 拆文分析结果存放目录
- `{书名}/正文/` — 长篇小说正文章节
- `{书名}/设定/` — 角色设定、世界设定
- `{书名}/大纲/` — 卷纲、细纲
- `{书名}/追踪/` — 上下文.md（写作上下文）、伏笔.md
- `{书名}/对标/` — 对标作品分析

## 协作规则

项目内置 7 个专业 Agent（通过 `.opencode/agents/` 定义），用于故事架构、角色设计、
叙事写作、一致性检查、资料研究、故事查询、章节提取。各 Agent 的职责边界由其定义文件
描述。使用 Task tool 调用子代理。

## Compact 后恢复上下文

写作中的关键上下文：
1. 当前写作项目名称和进度
2. 最近讨论的角色设定变更
3. 未完成的伏笔列表
4. 当前章节的情绪/节奏目标

如果存在 `{书名}/追踪/上下文.md`，compact 后首先读取恢复上下文。

## 同步上游

当用户说「同步」「拉取上游」「pull claudecode」「更新项目」时执行。

**远程**：`claudecode` → `D:\gz\skills\oh-story-claudecode`（已添加为 git remote）

**流程**：
1. 读取 `.sync-marker` 获取上次同步的 claudecode commit
2. `git fetch claudecode` 获取最新
3. `git diff --name-only <marker>..claudecode/main` 列出变更文件
4. 过滤跳过的目录/文件：`.claude-plugin/`、`.claude/`、`.omc/`、`opencode.json`、`AGENTS.md`、`.story-deployed`
5. 对每个文件复制 + 应用替换：
   - `.claude/agents/` → `.opencode/agents/`
   - `.claude/skills/` → `.opencode/skills/`
   - `CLAUDE.md` → `AGENTS.md`
   - `settings.local.json` → `opencode.json`
   - `Agent(` → `Task 工具 spawn `（改 Claude Code Agent 调用为 OpenCode Task tool spawn）
6. 优先处理 SKILL.md 中的语法冲突，保留 OpenCode 版本模式：
   - `.claude/agents/` 引用 → `.opencode/agents/`
   - 路径中的 `CLAUDE.md` → `AGENTS.md`
   - 对照已有 `.opencode/agents/` 引用风格做上下文感知修正
7. `git add -A && git commit -m "sync: update from oh-story-claudecode"`
8. `git push origin main`
9. 更新 `.sync-marker` 为 claudecode 最新 HEAD commit

**验证**：若步骤 3 返回空，回复「已是最新，无需同步」。
