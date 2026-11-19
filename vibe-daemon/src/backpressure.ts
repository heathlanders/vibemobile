// Backpressure on WebSocket sends (proposal 69 R10). `send()` queues in memory
// when the phone reads slower than we write; without a cap a slow link plus heavy
// output grows the daemon without bound.

import type { WebSocket } from "ws";

export const WS_HIGH_WATER = 1 << 20; // 1 MiB queued → back off
export const WS_LOW_WATER = 256 << 10; // drained below 256 KiB → resume

// Chat: stream deltas are a preview of text the final `assistant` frame (and the
// history replay on reconnect) carries in full, so they are the safe ones to drop.
const DROPPABLE = new Set(["delta", "thinking_delta"]);

export function sendFrame(ws: WebSocket, frame: Record<string, unknown>): void {
  if (ws.readyState !== ws.OPEN) return;
  if (DROPPABLE.has(frame.t as string) && ws.bufferedAmount > WS_HIGH_WATER) return;
  ws.send(JSON.stringify(frame));
}

// PTY: never drop terminal bytes (that corrupts the screen); pause the pty instead.
// tmux keeps the output, and the kernel pipe stops the shell if it keeps writing.
// Each send's callback fires as its bytes leave; the first one that finds the
// queue drained resumes.
type Pausable = { onData(cb: (data: string) => void): unknown; pause(): void; resume(): void };
export function pipePty(term: Pausable, socket: WebSocket): void {
  let paused = false;
  term.onData((data) => {
    if (socket.readyState !== socket.OPEN) return;
    socket.send(data, () => {
      if (paused && socket.bufferedAmount < WS_LOW_WATER) {
        paused = false;
        term.resume();
      }
    });
    if (!paused && socket.bufferedAmount > WS_HIGH_WATER) {
      paused = true;
      term.pause();
    }
  });
}
