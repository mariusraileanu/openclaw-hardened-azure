import fs from "node:fs";
import path from "node:path";

const repoRoot = process.cwd();
const envName = process.env.ENV || process.argv[2] || "dev";
const allowedEnvs = new Set(["dev", "stage", "prod"]);

if (!allowedEnvs.has(envName)) {
  throw new Error(`Unsupported ENV '${envName}'. Use one of: dev, stage, prod.`);
}

const manifestPath = path.join(repoRoot, "teams-app", "dist", envName, "manifest.json");

if (!fs.existsSync(manifestPath)) {
  throw new Error(`Rendered manifest not found: ${manifestPath}`);
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const requiredFields = [
  "manifestVersion",
  "version",
  "id",
  "name",
  "description",
  "bots",
  "validDomains",
];

for (const field of requiredFields) {
  if (!(field in manifest)) {
    throw new Error(`Manifest missing required field: ${field}`);
  }
}

if (!manifest.name.short || !manifest.name.full) {
  throw new Error("Manifest name.short and name.full are required.");
}

if (!manifest.description.short || !manifest.description.full) {
  throw new Error("Manifest description.short and description.full are required.");
}

if (!Array.isArray(manifest.bots) || manifest.bots.length === 0) {
  throw new Error("Manifest must include at least one bot.");
}

if (!manifest.bots[0].botId || manifest.bots[0].botId !== manifest.id) {
  throw new Error("Manifest bots[0].botId must match manifest id.");
}

if (!Array.isArray(manifest.validDomains) || manifest.validDomains.length === 0) {
  throw new Error("Manifest validDomains must contain at least one domain.");
}

const domain = manifest.validDomains[0];
if (envName === "dev" && !domain.includes("-dev.")) {
  throw new Error("Dev manifest domain must include '-dev.'.");
}
if (envName === "stage" && !domain.includes("-stage.")) {
  throw new Error("Stage manifest domain must include '-stage.'.");
}
if (envName === "prod" && (domain.includes("-dev.") || domain.includes("-stage."))) {
  throw new Error("Prod manifest domain must not include dev/stage markers.");
}

console.log(`Manifest checks passed for ENV=${envName}`);
