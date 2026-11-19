// Auto-mode Bash ask-list (proposal 69 R9; security.md #7). file-scope.ts keeps
// file tools inside the projects, but Bash can't be contained that way. These
// shapes go to the phone even in Auto mode instead of running unattended:
//   - a download run by a shell or interpreter: piped into one that reads stdin,
//     substituted into a command, or saved and then run in the same command;
//   - a recursive rm (or find -delete / -exec rm) on a path outside the allowed
//     dirs, or one we can't resolve (~, $VAR, {}, no path, an untracked cd);
//   - anything naming keys, the daemon's env file or a persistence path.
// A tripwire for the obvious cases, not a sandbox: obfuscation (base64, eval of a
// variable, a symlink made in the same command, splitting across tool calls) gets
// past it. Ask mode is the control when that matters.

import { basename, resolve } from "node:path";
import { canonical, inside } from "./file-scope.js";

const MAX_COMMAND = 64 * 1024; // longer → ask (bounded work on the event loop)
const MAX_RM_PATHS = 200;
const FETCHERS = new Set(["curl", "wget"]);
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh", "fish"]);
const INTERPRETERS = new Set([...SHELLS, "python", "python3", "perl", "ruby", "node", "bun", "deno", "php"]);
const SUBST_FETCH = /(<\(|\$\(|`)\s*(curl|wget)\b/;
const SENSITIVE =
  /\.ssh(\/|\b)|\.config\/systemd\b|systemd\/(user|system)\b|\.config\/autostart\b|vibe-daemon\.env\b|\.((bash|zsh)rc|profile)(?![\w.-])|\bcrontab\b|\bsystemctl\s+(--user\s+)?(enable|link)\b/;

const strip = (t: string) => t.replace(/['"\\]/g, "");

// The command a stage runs: skip sudo/env/command/exec/nohup/time and their flags,
// basename the rest (`/bin/bash` → bash, `\rm` → rm once quotes/backslashes are gone).
function commandOf(tokens: string[]): { name: string; args: string[] } {
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (["sudo", "env", "command", "exec", "nohup", "time"].includes(basename(t))) {
      i++;
      while (i < tokens.length && (tokens[i].startsWith("-") || /^[A-Za-z_]\w*=/.test(tokens[i]))) {
        if (["-u", "-g", "-C", "-D"].includes(tokens[i])) i++; // sudo flag with a value
        i++;
      }
      continue;
    }
    break;
  }
  return { name: basename(tokens[i] ?? ""), args: tokens.slice(i + 1) };
}

// An interpreter reads its program from stdin when it has no script/-c/-e/-m.
function readsStdin(name: string, args: string[]): boolean {
  if (args.some((a) => ["-c", "-e", "-m", "-p", "-r", "--eval"].includes(a))) return false;
  const operands = args.filter((a) => !a.startsWith("-"));
  return operands.length === 0 || args.includes("-") || args.includes("-s") || !INTERPRETERS.has(name);
}

// `cmd1; cmd2 && cmd3 | cmd4` → pipelines of stages, each a token list. Subshell
// and substitution brackets become spaces so `(rm …)` and `$(rm …)` are seen.
function parse(command: string): string[][][] {
  const flat = command
    .replace(/'[^']*'|"[^"]*"/g, (q) => q.replace(/[;&|\n()`{}]/g, " ")) // separators inside quotes are text
    .replace(/\|&/g, "|") // |& pipes stderr too: still a pipe
    .replace(/[0-9]?>&[0-9-]?|&>>?/g, " ") // 2>&1, &> are redirects, not separators
    .replace(/\$\(|[`(){}]/g, (m) => (m === "{" || m === "}" ? ` ${m} ` : " "));
  return flat
    .split(/;|&&|\|\||\n|&/)
    .map((pipeline) =>
      pipeline
        .split("|")
        .map((stage) => stage.trim().split(/\s+/).map(strip).filter((t) => t && t !== "{" && t !== "}")),
    );
}

export function bashInScope(toolName: string, input: Record<string, unknown>, cwd: string, allowedDirs: string[]): boolean {
  if (toolName !== "Bash") return true;
  const command = input.command;
  if (typeof command !== "string") return false; // fail closed
  if (command.length > MAX_COMMAND) return false;
  if (SUBST_FETCH.test(command) || SENSITIVE.test(strip(command))) return false;

  const dirs = allowedDirs.map(canonical);
  const allowed = (p: string) => dirs.some((d) => inside(canonical(p), d));
  const pipelines = parse(command);
  const fetches = pipelines.some((p) => p.some((s) => FETCHERS.has(commandOf(s).name)));
  let dir: string | null = cwd; // null once a cd goes somewhere we can't follow
  let rmPaths = 0;

  // A path argument of a delete: must resolve inside the allowed dirs.
  const pathOk = (arg: string): boolean => {
    if (arg === "{}" || arg.startsWith("~") || arg.includes("$")) return false;
    if (!arg.startsWith("/") && dir === null) return false;
    return allowed(resolve(dir ?? cwd, arg));
  };

  for (const pipeline of pipelines) {
    let fetched = false;
    for (const stage of pipeline) {
      const { name, args } = commandOf(stage);
      if (FETCHERS.has(name)) fetched = true;
      else if (fetched && INTERPRETERS.has(name) && readsStdin(name, args)) return false; // curl … | sh

      // Download-then-run in one command: `curl -o x.sh … && sh x.sh`, `chmod +x`, `./x`.
      if (fetches) {
        const operands = args.filter((a) => !a.startsWith("-"));
        if ((SHELLS.has(name) || name === "source" || name === ".") && operands.length > 0) return false;
        if (name === "chmod" && args.some((a) => /\+x|[0-7]*[1357][0-7]{0,2}$/.test(a) && !a.startsWith("-"))) return false;
        if (stage[0]?.startsWith("./")) return false;
      }

      if (name === "cd" || name === "pushd") {
        const to = args.find((a) => !a.startsWith("-"));
        dir = to === undefined || to === "-" || to.startsWith("~") || to.includes("$") || dir === null ? null : resolve(dir, to);
        continue;
      }

      // rm anywhere in the stage (covers xargs rm, nice rm, git rm).
      const at = stage.findIndex((t) => basename(t) === "rm");
      if (at >= 0) {
        const rest = stage.slice(at + 1);
        const end = rest.indexOf("--");
        const flags = end < 0 ? rest.filter((t) => t.startsWith("-")) : rest.slice(0, end).filter((t) => t.startsWith("-"));
        const paths = end < 0 ? rest.filter((t) => !t.startsWith("-")) : [...rest.slice(0, end).filter((t) => !t.startsWith("-")), ...rest.slice(end + 1)];
        const recursive = flags.some((f) => f === "--recursive" || (/^-[^-]/.test(f) && /[rR]/.test(f)));
        if (recursive) {
          if (paths.length === 0) return false; // xargs rm -rf: paths come from elsewhere
          rmPaths += paths.length;
          if (rmPaths > MAX_RM_PATHS || !paths.every(pathOk)) return false;
        }
      }

      if (name === "find" && (stage.includes("-delete") || stage.some((t, i) => (t === "-exec" || t === "-execdir") && basename(stage[i + 1] ?? "") === "rm"))) {
        const roots = args.slice(0, Math.max(0, args.findIndex((a) => a.startsWith("-")))).filter(Boolean);
        if (!(roots.length ? roots : ["."]).every(pathOk)) return false;
      }
    }
  }
  return true;
}
