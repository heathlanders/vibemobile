// The checkout this test run lives in, wherever it was cloned. Tests that spawn
// sessions need a real project dir inside the allowed roots, so default the
// roots to its parent unless the environment already set them.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const REPO_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
process.env.VIBE_PROJECT_ROOTS ??= dirname(REPO_DIR);
