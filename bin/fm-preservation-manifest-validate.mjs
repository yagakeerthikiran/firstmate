#!/usr/bin/env node
// Vendored copy of DriveLog's manifest schema validator
// (yagakeerthikiran/drivelog scripts/dl-preservation-manifest-check.mjs,
// exported `validateManifest` function, pinned at branch
// guardian/preservation-evidence-check commit 55aae1e1, docs/PRESERVATION_MANIFEST.md).
//
// Vendored rather than fetched at runtime so bin/fm-preservation-manifest.sh
// can validate a manifest offline, before anything is committed or pushed,
// with no dependency on DriveLog's own CI or network reachability. This is
// schema-only: it does not call the GitHub API and does not check that a
// referenced blob actually exists at a pushed commit - that live check is
// DriveLog's own workflow (dl-preservation-manifest-check.mjs main()), which
// this repository does not run.
//
// If DriveLog's schema changes, re-sync this file from the pinned commit
// above and update the pin in this header and in
// bin/fm-preservation-manifest.sh's header. Do not fork or extend the schema
// here: this file owns the client-side copy, DriveLog owns the contract.

const SHA = /^[0-9a-f]{40}$/;
const SAFE_PATH = /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))(?!.*\\)[A-Za-z0-9._\/-]+$/;
const REQUIRED_CATEGORIES = new Set(["requirements", "decisions", "test_evidence", "branch_recovery", "final_handoff"]);
const PLACEHOLDER = /^(?:unknown|unavailable|missing|none|n\/a|pending|tbd|replace_)/i;

function isMeaningfulString(value) {
  return typeof value === "string" && value.trim().length > 0 && !PLACEHOLDER.test(value.trim());
}

function validateUniqueStringList(value, field, add) {
  if (!Array.isArray(value) || value.length === 0) {
    add(`${field} must be a non-empty array`);
    return;
  }
  const normalized = value.map((item) => typeof item === "string" ? item.trim() : "");
  if (normalized.some((item) => !item || PLACEHOLDER.test(item))) add(`${field} must contain only non-placeholder strings`);
  if (new Set(normalized).size !== normalized.length) add(`${field} must not contain duplicates`);
}

export function validateManifest(manifest, expected) {
  const errors = [];
  const add = (message) => errors.push(message);
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest)) return ["manifest must be a JSON object"];
  if (manifest.schema_version !== 1) add("schema_version must equal 1");
  if (manifest.application_repository !== expected.repository) add(`application_repository must equal ${expected.repository}`);
  if (manifest.pull_request_number !== expected.prNumber) add(`pull_request_number must equal ${expected.prNumber}`);
  if (manifest.application_head_sha !== expected.headSha) add(`application_head_sha must equal current PR head ${expected.headSha}`);
  if (manifest.application_base_ref !== expected.baseRef) add(`application_base_ref must equal ${expected.baseRef}`);
  if (manifest.preservation_status !== "complete") add("preservation_status must equal complete");
  if (!isMeaningfulString(manifest.firstmate?.session_id) || !isMeaningfulString(manifest.firstmate?.resume_reference)) add("firstmate.session_id and firstmate.resume_reference must be non-placeholder strings");
  if (typeof manifest.crew_participated !== "boolean") add("crew_participated must be a boolean");
  if (!Array.isArray(manifest.crew)) add("crew must be an array");
  if (manifest.crew_participated === true && (!Array.isArray(manifest.crew) || manifest.crew.length === 0)) add("crew must contain every participant when crew_participated is true");
  if (manifest.crew_participated === false && Array.isArray(manifest.crew) && manifest.crew.length !== 0) add("crew must be empty when crew_participated is false");
  if (manifest.crew_participated === false && !isMeaningfulString(manifest.no_crew_reason)) add("no_crew_reason is required when crew_participated is false");
  for (const [index, crew] of (Array.isArray(manifest.crew) ? manifest.crew : []).entries()) {
    if (![crew?.role, crew?.task, crew?.session_id, crew?.resume_reference].every(isMeaningfulString)) add(`crew[${index}] requires non-placeholder role, task, session_id and resume_reference`);
  }
  if (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0) add("artifacts must be a non-empty array");
  else {
    const seen = new Set();
    const categories = new Set();
    for (const [index, artifact] of manifest.artifacts.entries()) {
      if (!artifact?.path || !SAFE_PATH.test(artifact.path)) add(`artifacts[${index}].path is missing or unsafe`);
      if (!REQUIRED_CATEGORIES.has(artifact?.category)) add(`artifacts[${index}].category must be one of: ${[...REQUIRED_CATEGORIES].join(", ")}`); else categories.add(artifact.category);
      if (!artifact?.blob_sha || !SHA.test(artifact.blob_sha)) add(`artifacts[${index}].blob_sha must be a 40-character Git blob SHA`);
      if (seen.has(artifact?.path)) add(`duplicate artifact path: ${artifact.path}`);
      seen.add(artifact?.path);
    }
    for (const category of REQUIRED_CATEGORIES) if (!categories.has(category)) add(`missing required artifact category: ${category}`);
  }
  validateUniqueStringList(manifest.requirement_ids, "requirement_ids", add);
  validateUniqueStringList(manifest.decision_ids, "decision_ids", add);
  if (!manifest.generated_utc || Number.isNaN(Date.parse(manifest.generated_utc))) add("generated_utc must be a valid timestamp");
  if (manifest.local_only_artifacts !== 0) add("local_only_artifacts must equal 0");
  if (!Array.isArray(manifest.unpreserved_items) || manifest.unpreserved_items.length !== 0) add("unpreserved_items must be an empty array when preservation_status is complete");
  return errors;
}

// CLI wrapper: `node fm-preservation-manifest-validate.mjs <manifest.json> --repository <repo> --pr <n> --head <sha> --base <ref>`
// prints one `FAIL: ...` line per error and exits 1, or prints `PASS` and exits 0.
// bin/fm-preservation-manifest.sh is the only intended caller.
async function main() {
  const fs = await import("node:fs");
  const argv = process.argv.slice(2);
  const manifestPath = argv[0];
  if (!manifestPath || manifestPath.startsWith("--")) {
    console.error("usage: fm-preservation-manifest-validate.mjs <manifest.json> --repository <repo> --pr <n> --head <sha> --base <ref>");
    process.exit(2);
  }
  const expected = {};
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--repository") expected.repository = argv[++i];
    else if (a === "--pr") expected.prNumber = Number(argv[++i]);
    else if (a === "--head") expected.headSha = argv[++i];
    else if (a === "--base") expected.baseRef = argv[++i];
  }
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (e) {
    console.error(`FAIL: could not parse ${manifestPath}: ${e.message}`);
    process.exit(1);
  }
  const errors = validateManifest(manifest, expected);
  if (errors.length) {
    for (const e of errors) console.error(`FAIL: ${e}`);
    process.exit(1);
  }
  console.log("PASS");
}

if (import.meta.url === `file://${process.argv[1]}`) main();
