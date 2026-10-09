// Shared path-scoping guard (security.md #7). Both session creation (sessions.ts)
// and project creation (projects.ts) must refuse to act on a path outside the
// configured project roots — defence-in-depth against traversal in client input.

import { resolve, sep } from "node:path";
import { projectRoots } from "./scanner.js";

// True iff `path` resolves to a project root or a descendant of one.
export function pathInRoots(path: string): boolean {
  const p = resolve(path);
  return projectRoots().some((root) => {
    const r = resolve(root);
    return p === r || p.startsWith(r + sep);
  });
}
