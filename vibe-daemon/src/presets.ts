// Agent CLI presets (ADR 0016). Terminal sessions that start a coding-agent CLI
// (Codex, Gemini CLI, Aider, …) so any model's own agent runs on the box beside
// Claude. Security: the client sends a preset ID only — never a command string.
// The command is a fixed literal from this table, typed into a normal tmux shell,
// so a terminal preset grants nothing a plain terminal session doesn't already.
//
// Detection runs `command -v` in the operator's interactive bash, because these
// CLIs usually live on an nvm/pipx PATH that the systemd daemon's env lacks; the
// tmux shell the command is typed into sees the same PATH.

import { execFile } from "node:child_process";

export type Preset = { id: string; label: string; command: string };

export const PRESETS: readonly Preset[] = [
  { id: "claude", label: "Claude Code (TUI)", command: "claude" },
  { id: "codex", label: "Codex CLI", command: "codex" },
  { id: "gemini", label: "Gemini CLI", command: "gemini" },
  { id: "aider", label: "Aider", command: "aider" },
  { id: "opencode", label: "opencode", command: "opencode" },
  { id: "qwen", label: "Qwen Code", command: "qwen" },
  { id: "cursor-agent", label: "Cursor Agent", command: "cursor-agent" },
];

export function presetById(id: string): Preset | undefined {
  return PRESETS.find((p) => p.id === id);
}

type Detect = (commands: string[]) => Promise<string[]>;

// Which of [commands] resolve in an interactive bash. Commands are table literals
// passed as positional args ("$@"), never interpolated into the script.
const bashDetect: Detect = (commands) =>
  new Promise((resolve) => {
    execFile(
      "bash",
      ["-ic", 'for c in "$@"; do command -v "$c" >/dev/null 2>&1 && echo "$c"; done', "detect", ...commands],
      { timeout: 5000 },
      (_err, stdout) => resolve(String(stdout ?? "").split("\n").filter(Boolean)),
    );
  });

const TTL_MS = 5 * 60_000;
let cache: { at: number; ids: Set<string> } | null = null;

// Presets whose CLI is installed. Cached 5 min (installing one shows up soon after).
export async function installedPresets(detect: Detect = bashDetect): Promise<Preset[]> {
  if (!cache || Date.now() - cache.at > TTL_MS) {
    const found = new Set(await detect(PRESETS.map((p) => p.command)));
    cache = { at: Date.now(), ids: new Set(PRESETS.filter((p) => found.has(p.command)).map((p) => p.id)) };
  }
  return PRESETS.filter((p) => cache!.ids.has(p.id));
}

export function clearPresetCache(): void {
  cache = null;
}
