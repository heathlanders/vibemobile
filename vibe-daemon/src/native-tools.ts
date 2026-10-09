// Gated tools for the native engine (ADR 0008, security.md #11). Every tool routes
// through the SHARED PermissionGate before doing anything — approve-before-exec,
// auto-allow default, timeout-deny, per-decision audit — exactly like a Claude tool
// call. And every path is re-checked with pathInRoots (defence-in-depth, #7) so a
// native model can never read outside the configured project roots.
//
// Tier 2 (this file) is READ-ONLY and pure JS — no process spawn, no writes — so it
// carries a small security surface. Tier 3 (write/edit/bash) is deliberately NOT
// here; it gates on a security review (see ADR 0008 / milestones).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { resolve, join, relative } from "node:path";
import { tool, type ToolSet } from "ai";
import { z } from "zod";
import { pathInRoots } from "./paths.js";
import type { PermissionGate } from "./permission-gate.js";

// Capability dial (VIBE_NATIVE_TIER): 1 = chat only, 2 = + read-only tools (default),
// 3 = + write/bash (not built — treated as 2 until the Tier-3 security review lands).
export function nativeTier(): number {
  return Number(process.env.VIBE_NATIVE_TIER ?? 2);
}

const MAX_READ_BYTES = 100_000;
const MAX_LIST = 500;
const MAX_HITS = 200;
const MAX_WALK_FILES = 5_000;

type Send = (frame: Record<string, unknown>) => void;

// Resolve a tool path arg against the session cwd and enforce the root scope. Returns
// the absolute path, or null if it escapes the project roots (caller returns a denial).
function scoped(cwd: string, p: string | undefined): string | null {
  const abs = resolve(cwd, p ?? ".");
  return pathInRoots(abs) ? abs : null;
}

// Wrap an execute() in the permission gate: ask first, deny short-circuits. The gate
// emits the permission_request frame and audits the decision; NativeSession emits the
// tool_use/tool_result frames from the AI SDK fullStream.
function gated<I extends Record<string, unknown>>(
  gate: PermissionGate,
  name: string,
  run: (input: I) => string,
) {
  return async (input: I, opts?: { toolCallId?: string }): Promise<string> => {
    const decision = await gate.request(name, input, { toolUseID: opts?.toolCallId });
    if (decision.behavior !== "allow") return "Denied by user.";
    try {
      return run(input);
    } catch (e) {
      return `Error: ${(e as Error)?.message ?? String(e)}`;
    }
  };
}

// null when the tier is chat-only — NativeSession passes undefined tools to streamText.
export function buildNativeTools(gate: PermissionGate, cwd: string, _send: Send): ToolSet | undefined {
  if (nativeTier() < 2) return undefined;

  return {
    read_file: tool({
      description: "Read a UTF-8 text file within the project. Use for source, config, and docs.",
      inputSchema: z.object({ path: z.string().describe("File path, relative to the project or absolute") }),
      execute: gated(gate, "read_file", ({ path }) => {
        const abs = scoped(cwd, path);
        if (!abs) return "Path is outside the project roots (denied).";
        const buf = readFileSync(abs);
        const text = buf.subarray(0, MAX_READ_BYTES).toString("utf8");
        return buf.length > MAX_READ_BYTES ? `${text}\n… [truncated at ${MAX_READ_BYTES} bytes]` : text;
      }),
    }),

    list_dir: tool({
      description: "List the entries of a directory within the project (directories marked with a trailing /).",
      inputSchema: z.object({ path: z.string().optional().describe("Directory path; defaults to the project root") }),
      execute: gated(gate, "list_dir", ({ path }) => {
        const abs = scoped(cwd, path as string | undefined);
        if (!abs) return "Path is outside the project roots (denied).";
        const entries = readdirSync(abs, { withFileTypes: true })
          .slice(0, MAX_LIST)
          .map((e) => (e.isDirectory() ? `${e.name}/` : e.name));
        return entries.join("\n") || "(empty)";
      }),
    }),

    search_files: tool({
      description: "Search file contents under a directory for a regular expression. Returns file:line: matches.",
      inputSchema: z.object({
        pattern: z.string().describe("A JavaScript regular expression"),
        path: z.string().optional().describe("Directory to search; defaults to the project root"),
      }),
      execute: gated(gate, "search_files", ({ pattern, path }) => {
        const root = scoped(cwd, path as string | undefined);
        if (!root) return "Path is outside the project roots (denied).";
        let re: RegExp;
        try {
          re = new RegExp(pattern as string);
        } catch {
          return "Invalid regular expression.";
        }
        const hits: string[] = [];
        let walked = 0;
        const walk = (dir: string): void => {
          if (hits.length >= MAX_HITS || walked >= MAX_WALK_FILES) return;
          let ents: import("node:fs").Dirent[];
          try {
            ents = readdirSync(dir, { withFileTypes: true });
          } catch {
            return;
          }
          for (const e of ents) {
            if (hits.length >= MAX_HITS || walked >= MAX_WALK_FILES) return;
            if (e.name === ".git" || e.name === "node_modules") continue;
            const full = join(dir, e.name);
            if (!pathInRoots(full)) continue;
            if (e.isDirectory()) {
              walk(full);
            } else {
              walked++;
              try {
                if (statSync(full).size > MAX_READ_BYTES) continue;
                const lines = readFileSync(full, "utf8").split("\n");
                for (let i = 0; i < lines.length && hits.length < MAX_HITS; i++) {
                  if (re.test(lines[i])) hits.push(`${relative(cwd, full)}:${i + 1}: ${lines[i].trim()}`);
                }
              } catch {
                /* skip unreadable/binary */
              }
            }
          }
        };
        walk(root);
        return hits.length ? hits.join("\n") : "No matches.";
      }),
    }),
  };
}
