import fs from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();
const teamsDir = path.join(repoRoot, "channels", "teams-app");
const envName = process.env.ENV || process.argv[2] || "dev";
const allowedEnvs = new Set(["dev", "stage", "prod"]);

if (!allowedEnvs.has(envName)) {
  throw new Error(`Unsupported ENV '${envName}'. Use one of: dev, stage, prod.`);
}

const basePath = path.join(teamsDir, "base.manifest.json");
const overlayPath = path.join(teamsDir, "env", `${envName}.json`);
const outDir = path.join(teamsDir, "dist", envName);
const outPath = path.join(outDir, "manifest.json");

const base = JSON.parse(fs.readFileSync(basePath, "utf8"));
const overlay = JSON.parse(fs.readFileSync(overlayPath, "utf8"));

const merged = {
  ...base,
  ...overlay,
  name: { ...(base.name || {}), ...(overlay.name || {}) },
  description: { ...(base.description || {}), ...(overlay.description || {}) },
  developer: { ...(base.developer || {}), ...(overlay.developer || {}) },
  icons: { ...(base.icons || {}), ...(overlay.icons || {}) },
};

if (!Array.isArray(merged.bots) || merged.bots.length === 0) {
  throw new Error("Manifest must define at least one bot.");
}

const appId = merged.id;
if (!appId || typeof appId !== "string") {
  throw new Error("Manifest id is required.");
}

if (!merged.bots[0].botId) {
  merged.bots[0].botId = appId;
}

if (merged.bots[0].botId !== appId) {
  throw new Error(`bots[0].botId must match manifest id (${appId}).`);
}

if (!Array.isArray(merged.validDomains) || merged.validDomains.length === 0) {
  throw new Error(`validDomains must be non-empty for ENV=${envName}.`);
}

if (envName === "prod") {
  const prodSurface = JSON.stringify({
    name: merged.name,
    description: merged.description,
    validDomains: merged.validDomains,
  }).toLowerCase();
  if (prodSurface.includes("-dev") || prodSurface.includes("-stage") || prodSurface.includes("development") || prodSurface.includes("staging")) {
    throw new Error("Prod manifest contains dev/stage markers.");
  }
}

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(outPath, `${JSON.stringify(merged, null, 2)}\n`, "utf8");

console.log(`Rendered teams manifest: ${path.relative(repoRoot, outPath)}`);
