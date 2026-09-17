/**
 * Feeds a file the addon wrote to the site's own parser.
 *
 * The parser is not copied here. The script reads src/lib/lua-parser/parse.ts
 * and src/lib/companion/read.ts out of the application repository with git,
 * so the working tree of that read-only clone is never touched, rewrites the
 * one path alias those two files use for each other, bundles them with
 * esbuild, and calls readCompanionFile on the file. What passes here is what
 * the drop zone at everythingwow.com/addons/companion/upload accepts.
 *
 * Usage, from the repository root:
 *
 *   node addon/tests/check-file.mjs <file> [app clone] [git ref]
 *
 * The file is any file the addon wrote: the one addon/tests/run.lua writes, or
 * the anonymized live capture in addon/tests/fixtures/live-0.1.0.lua.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { build } from "esbuild";

const [, , filePath, clonePath = "/home/user/everythingwow", ref = "origin/main"] = process.argv;
if (!filePath) {
  console.error("Usage: node addon/tests/check-file.mjs <file> [app clone] [git ref]");
  process.exit(2);
}

const show = (path) =>
  execFileSync("git", ["-C", clonePath, "show", `${ref}:${path}`], { encoding: "utf8" });

const work = mkdtempSync(join(process.env.TMPDIR ?? tmpdir(), "ewow-parser-"));
writeFileSync(join(work, "parse.ts"), show("src/lib/lua-parser/parse.ts"));
writeFileSync(
  join(work, "read.ts"),
  // The only edit: the alias the application's bundler resolves becomes the
  // relative path beside it, so no application toolchain is needed here.
  show("src/lib/companion/read.ts").replace("@/lib/lua-parser/parse", "./parse"),
);

await build({
  entryPoints: [join(work, "read.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  outfile: join(work, "read.mjs"),
  logLevel: "silent",
});

const { readCompanionFile, summarize, OBSERVATION_KINDS } = await import(
  pathToFileURL(join(work, "read.mjs")).href
);

let passed = 0;
let failed = 0;
const check = (name, condition, detail) => {
  if (condition) {
    passed += 1;
  } else {
    failed += 1;
    console.log(`FAIL ${name}${detail === undefined ? "" : `: ${detail}`}`);
  }
};

const text = readFileSync(filePath, "utf8");
const result = readCompanionFile(text);
check("the site's parser accepts the file", result.ok, result.ok ? "" : result.reason);
if (!result.ok) {
  console.log(`${passed} passed, ${failed} failed.`);
  process.exit(1);
}

const file = result.file;
check("the version key is read", /^[a-z_]{1,32}$/.test(file.version), file.version);
check(
  "the addon version is read",
  typeof file.addon === "string" && /^\d+\.\d+\.\d+$/.test(file.addon),
  file.addon,
);
check("the patch is read", typeof file.patch === "string" && file.patch.length > 0, file.patch);
check("nothing in the file is dropped", file.dropped === 0, file.dropped);
check("observations are read", file.observations.length > 0, file.observations.length);

for (const observation of file.observations) {
  check(
    `the kind ${observation.kind} is one the site knows`,
    OBSERVATION_KINDS.includes(observation.kind),
    observation.kind,
  );
  if (observation.x !== null) {
    check(
      `${observation.kind} x is a fraction from 0 to 1`,
      observation.x >= 0 && observation.x <= 1,
      observation.x,
    );
  }
  if (observation.y !== null) {
    check(
      `${observation.kind} y is a fraction from 0 to 1`,
      observation.y >= 0 && observation.y <= 1,
      observation.y,
    );
  }
}

const npc = file.observations.find((observation) => observation.kind === "npc");
check("an npc sighting is read", npc !== undefined);
check("the subject id is emitted from id", npc?.subjectId !== null && npc?.subjectId !== undefined, npc?.subjectId);
check("the subject type is emitted from subject", npc?.subjectType === "npc", npc?.subjectType);
check("the map id is emitted from map", npc?.mapId !== null && npc?.mapId !== undefined, npc?.mapId);
check(
  "the observed time is emitted from t as an ISO string",
  typeof npc?.observedAt === "string" && !Number.isNaN(Date.parse(npc.observedAt)),
  npc?.observedAt,
);

const loot = file.observations.find((observation) => observation.kind === "loot");
const vendor = file.observations.find((observation) => observation.kind === "vendor");
const snapshot = file.observations.find((observation) => observation.kind === "character_snapshot");
const object = file.observations.find((observation) => observation.kind === "object");

// A file the game wrote holds whatever the player did, so a kind that is not
// in it is reported as absent rather than failed. The addon's own test file
// holds every kind, so nothing here is skipped for it.
const missing = [];
const present = (name, value) => {
  if (value !== undefined) return true;
  missing.push(name);
  return false;
};

if (present("loot", loot)) {
  check("loot items are spelled items", Array.isArray(loot?.payload?.items), JSON.stringify(loot?.payload)?.slice(0, 120));
  check("a loot item id is spelled id", typeof loot?.payload?.items?.[0]?.id === "number");
  check("the loot source type is spelled source_type", loot?.payload?.source_type === "npc");
  check("the loot source id is spelled source_id", typeof loot?.payload?.source_id === "number");
}

if (present("vendor", vendor)) {
  check("vendor items are spelled items", Array.isArray(vendor?.payload?.items));
  check("a vendor item id is spelled id", typeof vendor?.payload?.items?.[0]?.id === "number");
  check("a vendor price is spelled price", typeof vendor?.payload?.items?.[0]?.price === "number");
}

if (present("character_snapshot", snapshot)) {
  check(
    "the snapshot payload is inside its own cap",
    new TextEncoder().encode(JSON.stringify(snapshot?.payload ?? null)).length <= 64_000,
  );
}

// The other half of the round trip: the worker's own aggregation readers.
// The same file has to be legible to them, because they are what turns these
// payloads into drop rates, vendor stock, and pins.
await build({
  entryPoints: [join(process.cwd(), "src/sync/companion.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  outfile: join(work, "companion.mjs"),
  logLevel: "silent",
});
const aggregator = await import(pathToFileURL(join(work, "companion.mjs")).href);

const asRow = (observation) => ({
  seq: 1,
  id: "00000000-0000-0000-0000-000000000000",
  upload_id: "00000000-0000-0000-0000-000000000000",
  kind: observation.kind,
  version_key: file.version,
  subject_type: observation.subjectType,
  subject_id: observation.subjectId,
  map_id: observation.mapId,
  x: observation.x,
  y: observation.y,
  payload: observation.payload,
  observed_at: observation.observedAt,
  received_at: new Date().toISOString(),
  contributor_hash: "0".repeat(64),
  account_backed: true,
  trust_score: null,
});

if (loot !== undefined) {
  const lootRow = asRow(loot);
  check("the worker reads the loot item ids", aggregator.lootItemIds(lootRow.payload).length > 0);
  check("the worker reads the loot source", aggregator.lootSource(lootRow)?.source_type === "npc");
  check(
    "the worker reads the loot source id",
    aggregator.lootSource(lootRow)?.source_id === loot.payload.source_id,
  );
}
if (vendor !== undefined) {
  const vendorLines = aggregator.vendorItems(asRow(vendor).payload);
  check("the worker reads the vendor lines", vendorLines.length > 0, vendorLines.length);
  check("the worker reads a vendor price in copper", typeof vendorLines[0]?.price === "number");
  check("the worker reads a vendor currency where there is one", vendorLines[0]?.currency !== undefined);
}
if (npc !== undefined) {
  check("the worker takes the npc sighting as a pin", aggregator.isPinEligible(asRow(npc)) === true);
}
if (present("object", object)) {
  check("the worker takes the node sighting as a pin", aggregator.isPinEligible(asRow(object)) === true);
}

// What the site would publish from this file on its own: a pin needs two
// account backed contributors or one trusted one, so one file publishes
// nothing until a second contributor agrees.
const pinnable = file.observations.filter((observation) => aggregator.isPinEligible(asRow(observation)));
console.log(
  `${pinnable.length} of ${file.observations.length} observations are pin eligible; ` +
    `one contributor is below the gate of ${aggregator.PIN_GATE_CONTRIBUTORS} account backed contributors ` +
    `(or one at trust ${aggregator.PIN_GATE_TRUST}), so nothing is published from this file alone.`,
);
if (missing.length > 0) console.log(`Not in this file: ${missing.join(", ")}.`);

const summary = summarize(file.observations);
console.log(
  `${passed} passed, ${failed} failed. ${file.observations.length} observations read: ` +
    Object.entries(summary)
      .filter(([, count]) => count > 0)
      .map(([kind, count]) => `${kind} ${count}`)
      .join(", "),
);
process.exit(failed > 0 ? 1 : 0);
