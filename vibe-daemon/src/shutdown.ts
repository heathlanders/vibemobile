// Graceful stop on SIGTERM/SIGINT (proposal 69 R5): tell every WebSocket client
// the server is restarting (1012, which the app retries), let in-flight requests
// finish, then close the DB so WAL is checkpointed instead of cut off mid-write.
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";

export async function stopDaemon(app: FastifyInstance, db: DB): Promise<void> {
  for (const socket of app.websocketServer.clients) socket.close(1012, "server restarting");
  await app.close();
  db.close();
}
