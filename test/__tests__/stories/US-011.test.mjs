// US-010 deleted core/scripts/work-mesh.mjs (old client layer).
// Former US-011 watcher acceptance is superseded by work-mesh-live hooks.
import test from "node:test";
test("work-mesh.mjs removed by US-010", async () => {
  const fs = await import("node:fs");
  const path = await import("node:path");
  const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../..");
  if (fs.existsSync(path.join(root, "core/scripts/work-mesh.mjs"))) {
    throw new Error("work-mesh.mjs should be deleted");
  }
});
