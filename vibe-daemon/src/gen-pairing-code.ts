// Physical-access pairing path (security #3): run this AT the server to mint a
// one-time pairing code, then type it into the phone's pair screen. The code is
// single-use, expires in 10 minutes, and only its hash is persisted.
//
//   npm run pair:new

import { openDb } from "./db.js";
import { createPairingCode, logEvent } from "./auth.js";

const db = openDb();
const code = createPairingCode(db);
logEvent(db, "pair.code", null, "server");
const pretty = `${code.slice(0, 4)}-${code.slice(4)}`;
console.log(`\n  Pairing code:  ${pretty}\n  Single use, expires in 10 minutes.\n`);
