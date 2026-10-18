// One async serial lock per checkout root (ADR 0032 §1). git-write.ts, project-files.ts and
// the merge queue all take it, so a merge can't interleave with a phone git write or a file
// save on the same checkout. Keyed by realpath, so a symlinked path shares the lock.

import { realpathSync } from "node:fs";

const locks = new Map<string, Promise<unknown>>();

const keyOf = (root: string): string => {
  try {
    return realpathSync(root);
  } catch {
    return root;
  }
};

// Not re-entrant: never call withProjectLock for the same root from inside `fn`.
export function withProjectLock<T>(root: string, fn: () => Promise<T>): Promise<T> {
  const key = keyOf(root);
  const run = (locks.get(key) ?? Promise.resolve()).catch(() => {}).then(fn);
  locks.set(key, run);
  void run.finally(() => locks.get(key) === run && locks.delete(key)).catch(() => {});
  return run;
}
