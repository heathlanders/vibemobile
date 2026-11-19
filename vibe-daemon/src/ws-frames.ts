// Incoming WebSocket frames, validated at the boundary (proposal 72 Q3). A frame
// that is not one of these shapes is dropped before any handler sees it, so a
// handler never runs on `null`, a number or a mistyped field. Value checks that
// need session state (mode names, MCP server names, effort levels) stay where
// they are; this only fixes the shape.

import { z } from "zod";

const ClientFrame = z.discriminatedUnion("t", [
  z.object({ t: z.literal("user"), text: z.string(), images: z.array(z.string()).optional() }),
  z.object({ t: z.literal("permission"), toolUseID: z.string(), allow: z.boolean() }),
  z.object({ t: z.literal("auto_allow"), on: z.boolean() }),
  z.object({ t: z.literal("mode"), mode: z.string() }),
  z.object({ t: z.literal("dialog_response"), dialogId: z.string(), completed: z.boolean(), result: z.unknown().optional() }),
  z.object({ t: z.literal("interrupt") }),
  z.object({ t: z.literal("set_model"), model: z.string() }),
  z.object({ t: z.literal("compact") }),
  z.object({ t: z.literal("get_mcp") }),
  z.object({ t: z.literal("mcp_action"), server: z.string(), action: z.string() }),
  z.object({ t: z.literal("set_effort"), effort: z.string().nullable() }),
]);
export type ClientFrame = z.infer<typeof ClientFrame>;

/** Chat socket (`/session/:id`) frame, or null if it is not valid JSON of a known shape. */
export function parseClientFrame(raw: string): ClientFrame | null {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return null;
  }
  const r = ClientFrame.safeParse(json);
  return r.success ? r.data : null;
}

const Resize = z.object({ cols: z.number().int().min(1).max(1000), rows: z.number().int().min(1).max(1000) });

/** PTY resize body (`'1'` + JSON), or null. Used by `/pty` and `/tty`. */
export function parseResize(raw: string): { cols: number; rows: number } | null {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return null;
  }
  const r = Resize.safeParse(json);
  return r.success ? r.data : null;
}
