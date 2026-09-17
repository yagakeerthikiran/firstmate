#!/usr/bin/env node
// Deterministic checkpoint validator for the AgentLab evidence-preservation
// lifecycle. Canonical contract: docs/evidence-preservation-lifecycle.md
// (captain's directive section 8: "mechanical enforcement, not prose
// instructions alone").
//
// Usage:
//   node scripts/validate-checkpoint.mjs <checkpoint.md> \
//     [--repo-root <agentlab clone>] [--app-repo <path>] [--offline] \
//     [--kind <initial|update|final|crew-report>] [--require-pushed] \
//     [--durable-branch <name>] [--working-tree]
//
// --working-tree: validate a not-yet-committed draft (used by
//   scripts/publish-firstmate-checkpoint.sh's pre-commit pass). Skips the
//   "tracked in git ls-tree HEAD" and "reachable from origin" artifact
//   checks -- existence on disk with a durable manifest status is enough at
//   this stage. Re-run without this flag after commit+push for the real
//   pushed-ness/reachability guarantee.
//
// Exit 0 on pass. Non-zero with one line per failure otherwise. Each failure
// line is tagged with one of the captain's nine minimum failure conditions
// (section 8) so tests and humans can grep for the condition, e.g.:
//   FAIL[UNCOMMITTED_LOCAL_ARTIFACT]: data/foo/report.md has no committed
//   durable counterpart in artifacts/**/MANIFEST.json
//
// See scripts/checkpoint-lib.mjs for the header-field / heading structure
// this validates against (shared with scripts/checkpoint-template.sh).

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  KINDS,
  headerFieldsForKind,
  sectionsForKind,
  hasBranchRecoveryRecord,
  BRANCH_RECOVERY_HEADING,
  BRANCH_RECOVERY_FIELDS,
} from './checkpoint-lib.mjs';

const FAILURE_CONDITIONS = {
  UNCOMMITTED_LOCAL_ARTIFACT: 'A report cites data/..., tmp/..., a worktree path or another local artifact that has no committed durable counterpart.',
  MISSING_MOCKUP: 'A Lavish/mock-up file is mentioned but absent.',
  UNRECORDED_DECISION: 'A decision is referenced without being recorded.',
  MISSING_FIRSTMATE_SESSION: 'The FirstMate resume session is missing.',
  MISSING_SUPERVISING_FIRSTMATE: "A crew report lacks its supervising FirstMate session.",
  ARTIFACT_INVENTORY_MISMATCH: 'The artifact inventory disagrees with GitHub.',
  STALE_CHECKPOINT: 'A teardown summary predates the latest requirement, decision, branch head or mock-up change.',
  NOT_PUSHED: 'Files are committed locally but not pushed.',
  UNRESOLVABLE_REFERENCE: 'A report points to a commit/PR/SHA that cannot be resolved.',
};

function parseArgs(argv) {
  const args = { _: [], offline: false, requirePushed: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--repo-root') args.repoRoot = argv[++i];
    else if (a === '--app-repo') args.appRepo = argv[++i];
    else if (a === '--offline') args.offline = true;
    else if (a === '--kind') args.kind = argv[++i];
    else if (a === '--require-pushed') args.requirePushed = true;
    else if (a === '--durable-branch') args.durableBranch = argv[++i];
    else if (a === '--working-tree') args.workingTree = true;
    else args._.push(a);
  }
  return args;
}

function sh(cwd, cmd, cmdArgs) {
  try {
    return execFileSync(cmd, cmdArgs, {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 256 * 1024 * 1024,
    }).trim();
  } catch (e) {
    return null;
  }
}

function sha256File(p) {
  return createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

const trackedAtHeadCache = new Map();
function trackedAtHead(repoRoot) {
  if (!trackedAtHeadCache.has(repoRoot)) {
    const out = sh(repoRoot, 'git', ['ls-tree', '-r', '--name-only', 'HEAD']);
    trackedAtHeadCache.set(repoRoot, new Set(out ? out.split('\n') : []));
  }
  return trackedAtHeadCache.get(repoRoot);
}

function findFiles(root, name) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) stack.push(full);
      else if (e.name === name) out.push(full);
    }
  }
  return out;
}

function loadManifests(repoRoot) {
  const files = findFiles(path.join(repoRoot, 'artifacts'), 'MANIFEST.json');
  const manifests = [];
  for (const f of files) {
    try {
      const data = JSON.parse(fs.readFileSync(f, 'utf8'));
      manifests.push({ file: f, data });
    } catch {
      // malformed manifest is reported separately by structural checks if referenced
    }
  }
  return manifests;
}

function allManifestEntries(manifests) {
  const out = [];
  for (const m of manifests) {
    const entries = Array.isArray(m.data.entries) ? m.data.entries : (Array.isArray(m.data) ? m.data : []);
    for (const e of entries) out.push({ ...e, __manifestFile: m.file });
  }
  return out;
}

function normalizeForMatch(p) {
  return p.replace(/^\.\//, '').replace(/\/+$/, '');
}

// MANIFEST.json `agentlab_path` values are written relative to artifacts/
// (matching the existing artifacts/firstmate-home/MANIFEST.json convention),
// not relative to the repo root. Accept either form.
function resolveAgentlabPath(repoRoot, agentlabPath) {
  const rel = agentlabPath.startsWith('artifacts/') ? agentlabPath : path.join('artifacts', agentlabPath);
  return { rel, abs: path.join(repoRoot, rel) };
}

function findManifestEntryForCitation(entries, citation) {
  const norm = normalizeForMatch(citation);
  if (norm.length < 6) return null;
  let best = null;
  for (const e of entries) {
    const src = e.source_path_non_durable || e.source_path || '';
    if (!src) continue;
    const nsrc = normalizeForMatch(src);
    if (nsrc === norm || nsrc.endsWith('/' + norm) || norm.endsWith('/' + nsrc) || nsrc.includes(norm) || norm.includes(nsrc)) {
      best = e;
      break;
    }
  }
  return best;
}

const DURABLE_STATUSES = new Set(['PRESERVED', 'REDACTED', 'RECONSTRUCTED']);
const EXCLUDED_STATUSES = new Set(['EXCLUDED', 'EXCLUDED_BY_NAME']);

function extractHeaderBlock(text) {
  const m = text.match(/## Session identification\s*\n+```text\n([\s\S]*?)\n```/);
  const fields = {};
  if (!m) return fields;
  for (const line of m[1].split('\n')) {
    const idx = line.indexOf(':');
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    const val = line.slice(idx + 1).trim();
    fields[key] = val;
  }
  return fields;
}

function extractHeadings(text) {
  const out = [];
  const re = /^##\s+(?:\d+\.\s+)?(.+)$/gm;
  let m;
  while ((m = re.exec(text))) out.push(m[1].trim());
  return out;
}

function extractBranchRecoveryFields(text) {
  const m = text.match(new RegExp(`##\\s+${BRANCH_RECOVERY_HEADING}\\s*\\n([\\s\\S]*?)(?:\\n##\\s|$)`));
  const fields = {};
  if (!m) return fields;
  const re = /^-\s+([^:]+):\s*(.*)$/gm;
  let mm;
  while ((mm = re.exec(m[1]))) fields[mm[1].trim()] = mm[2].trim();
  return fields;
}

function isUnavailableOk(value) {
  if (!value) return false;
  const m = value.match(/^UNAVAILABLE\b\s*(.*)$/);
  if (!m) return false;
  return m[1].trim().length > 0;
}

function fieldOk(value) {
  if (value === undefined) return false;
  const v = value.trim();
  if (v.length === 0) return false;
  if (v.toUpperCase().startsWith('UNAVAILABLE')) return isUnavailableOk(v);
  return true;
}

// --- citation scanning (checks c & d) --------------------------------------

const CITATION_PATTERNS = [
  { re: /\bdata\/[A-Za-z0-9._\-\/]+/g, kind: 'local' },
  { re: /\/tmp\/[A-Za-z0-9._\-\/]+/g, kind: 'local' },
  { re: /(?<![\/\w])tmp\/[A-Za-z0-9._\-\/]+/g, kind: 'local' },
  { re: /\/home\/user\/\.treehouse\/[A-Za-z0-9._\-\/]+/g, kind: 'local' },
  { re: /\/home\/user\/github\/firstmate\/[A-Za-z0-9._\-\/]+/g, kind: 'local' },
  { re: /\.lavish\/[A-Za-z0-9._\-\/]+/g, kind: 'mockup' },
  { re: /[A-Za-z0-9._\-\/]*mock[A-Za-z0-9._\-\/]*\.html/gi, kind: 'mockup' },
];

function stripTrailingPunct(s) {
  return s.replace(/[.,;:'")\]`]+$/, '');
}

function scanCitations(text) {
  const lines = text.split('\n');
  const found = new Map(); // citation -> {kind, lineIdx, line}
  lines.forEach((line, idx) => {
    // Directive section 4 explicitly permits the branch recovery record's
    // worktree-path field to hold a non-durable local path "as historical
    // context" -- it is not evidence that needs a durable counterpart.
    if (/^-\s*Worktree path \(historical context, non-durable\)\s*:/i.test(line.trim())) return;
    // Heading lines are structural (e.g. a required "All Lavish source/output
    // files" section heading), not evidence citations -- don't scan them.
    if (/^#{1,6}\s/.test(line.trim())) return;
    for (const { re, kind } of CITATION_PATTERNS) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(line))) {
        const citation = stripTrailingPunct(m[0]);
        if (citation.length < 6) continue;
        if (!found.has(citation)) found.set(citation, { kind, lineIdx: idx, line });
      }
    }
    if (/\bLavish\b/.test(line) && !/\.lavish\//.test(line) && !/mock.*\.html/i.test(line)) {
      const key = `Lavish-mention:${idx}`;
      found.set(key, { kind: 'mockup-mention', lineIdx: idx, line, isWordMention: true });
    }
  });
  return found;
}

function lineHasMissingMarker(line) {
  return /MISSING EVIDENCE:|EXCLUDED:/i.test(line);
}

function markerExplanationOk(line) {
  const m = line.match(/(MISSING EVIDENCE:|EXCLUDED:)(.*)$/i);
  if (!m) return false;
  return m[2].trim().length >= 8;
}

// --- decision reference scanning (check e) ----------------------------------

function scanDecisionRefs(text) {
  const ids = new Set();
  const dRe = /\bD-\d+\b/g;
  let m;
  while ((m = dRe.exec(text))) ids.add(m[0]);
  const phraseHit = /captain decided|captain ruling/i.test(text);
  return { ids: [...ids], phraseHit };
}

function ledgerDeclaredIds(ledgerText) {
  const ids = new Set();
  const re = /^###\s+(D-\d+)\b/gm;
  let m;
  while ((m = re.exec(ledgerText))) ids.add(m[1]);
  return ids;
}

function ledgerEntryDates(ledgerText) {
  const dates = [];
  const re = /^###\s+D-\d+\s*—\s*([0-9T:\-Z]+)/gm;
  let m;
  while ((m = re.exec(ledgerText))) {
    const d = new Date(m[1]);
    if (!isNaN(d.getTime())) dates.push(d);
  }
  return dates;
}

// --- SHA / PR reference scanning (check f) ----------------------------------

function scanShaRefs(text) {
  // A bare 7-40 char lowercase hex token, not touching a hyphen or other word
  // char at either edge (excludes UUID segments like session IDs, which are
  // hyphen-delimited hex-looking groups, not commit SHAs).
  const shas = new Set();
  const re = /(?<![\w-])(?=[0-9a-f]{7,40}(?![\w-]))[0-9a-f]*[a-f][0-9a-f]*(?![\w-])/g;
  let m;
  while ((m = re.exec(text))) {
    if (m[0].length >= 7 && m[0].length <= 40) shas.add(m[0]);
  }
  return [...shas];
}

function scanPrRefs(text) {
  const prs = [];
  const urlRe = /https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/g;
  let m;
  while ((m = urlRe.exec(text))) prs.push({ owner: m[1], repo: m[2], num: m[3], raw: m[0] });
  const hashRe = /#(\d{1,6})\b/g;
  while ((m = hashRe.exec(text))) prs.push({ owner: null, repo: null, num: m[1], raw: m[0] });
  return prs;
}

function gitRemoteOwnerRepo(repoRoot) {
  const url = sh(repoRoot, 'git', ['remote', 'get-url', 'origin']);
  if (!url) return null;
  const m = url.match(/github\.com[:/]+([\w.-]+)\/([\w.-]+?)(?:\.git)?$/);
  if (!m) return null;
  return { owner: m[1], repo: m[2] };
}

// --- artifact inventory table (check g) -------------------------------------

function findInventoryTables(text) {
  const tables = [];
  const sectionRe = /##\s+(?:\d+\.\s+)?([^\n]*[Aa]rtifact[^\n]*)\n([\s\S]*?)(?:\n##\s|$)/g;
  let sm;
  while ((sm = sectionRe.exec(text))) {
    const body = sm[2];
    const rows = body.split('\n').filter((l) => l.trim().startsWith('|'));
    if (rows.length < 2) continue;
    const header = rows[0].split('|').map((c) => c.trim().toLowerCase());
    const pathIdx = header.findIndex((c) => c.includes('path'));
    const shaIdx = header.findIndex((c) => c.includes('sha'));
    if (pathIdx === -1 || shaIdx === -1) continue;
    const dataRows = rows.slice(2); // skip header + separator
    for (const r of dataRows) {
      const cells = r.split('|').map((c) => c.trim());
      const p = (cells[pathIdx + 1] || '').replace(/`/g, '');
      const s = (cells[shaIdx + 1] || '').replace(/`/g, '');
      if (p) tables.push({ path: p, sha256: s });
    }
  }
  return tables;
}

// --- main --------------------------------------------------------------

function main() {
  const args = parseArgs(process.argv.slice(2));
  const filePath = args._[0];
  if (!filePath) {
    console.error('usage: node validate-checkpoint.mjs <checkpoint.md> [--repo-root <path>] [--app-repo <path>] [--offline] [--kind <kind>] [--require-pushed] [--durable-branch <name>] [--working-tree]');
    process.exit(2);
  }
  if (!fs.existsSync(filePath)) {
    console.error(`FAIL[STRUCTURAL]: checkpoint file not found: ${filePath}`);
    process.exit(1);
  }

  const repoRoot = args.repoRoot ? path.resolve(args.repoRoot) : sh(path.dirname(path.resolve(filePath)), 'git', ['rev-parse', '--show-toplevel']) || process.cwd();
  const rawText = fs.readFileSync(filePath, 'utf8');
  // Strip HTML comments (authoring guidance, e.g. from checkpoint-lib.mjs's
  // template) before scanning content, so instructional text about forbidden
  // words/markers is never itself mistaken for checkpoint content.
  const text = rawText.replace(/<!--[\s\S]*?-->/g, '');
  const absFilePath = path.resolve(filePath);
  const relFilePath = path.relative(repoRoot, absFilePath);

  const failures = [];
  const fail = (tag, detail) => failures.push(`FAIL[${tag}]: ${detail} (${FAILURE_CONDITIONS[tag] || 'structural'})`);
  const failPlain = (tag, detail) => failures.push(`FAIL[${tag}]: ${detail}`);

  // ---- determine kind ----
  let kind = args.kind;
  const fnMatch = path.basename(filePath).match(/--(initial|update|final|crew-report)\.md$/);
  if (!kind && fnMatch) kind = fnMatch[1];
  if (!kind) {
    failPlain('STRUCTURAL', `cannot determine checkpoint kind from filename '${path.basename(filePath)}'; pass --kind explicitly`);
    kind = 'initial';
  } else if (!KINDS.includes(kind)) {
    failPlain('STRUCTURAL', `unknown checkpoint kind '${kind}'; expected one of ${KINDS.join(', ')}`);
  }

  // ---- (a) header fields ----
  const header = extractHeaderBlock(text);
  const requiredFields = headerFieldsForKind(kind);
  for (const f of requiredFields) {
    if (!fieldOk(header[f])) {
      if (f.includes('FirstMate') && f.includes('session')) {
        fail('MISSING_FIRSTMATE_SESSION', `header field '${f}' is missing, empty, or UNAVAILABLE without a reason`);
      } else if (f.includes('Supervising FirstMate') && f.includes('session')) {
        fail('MISSING_SUPERVISING_FIRSTMATE', `header field '${f}' is missing, empty, or UNAVAILABLE without a reason`);
      } else {
        failPlain('MISSING_HEADER_FIELD', `header field '${f}' is missing, empty, or UNAVAILABLE without a reason`);
      }
    }
  }
  if (kind === 'crew-report') {
    if (!fieldOk(header['Supervising FirstMate session ID'])) {
      fail('MISSING_SUPERVISING_FIRSTMATE', "crew report missing 'Supervising FirstMate session ID'");
    }
    if (!fieldOk(header['Supervising FirstMate resume URL'])) {
      fail('MISSING_SUPERVISING_FIRSTMATE', "crew report missing 'Supervising FirstMate resume URL'");
    }
  } else {
    if (!fieldOk(header['FirstMate Claude session ID'])) {
      fail('MISSING_FIRSTMATE_SESSION', "checkpoint missing 'FirstMate Claude session ID'");
    }
    if (!fieldOk(header['FirstMate resume URL'])) {
      fail('MISSING_FIRSTMATE_SESSION', "checkpoint missing 'FirstMate resume URL'");
    }
  }

  // ---- (b) required section headings ----
  const headings = extractHeadings(text);
  const requiredSections = sectionsForKind(kind);
  for (const s of requiredSections) {
    if (!headings.some((h) => h.toLowerCase().includes(s.toLowerCase().split(' (')[0].slice(0, 20).toLowerCase()) || h.trim() === s.trim())) {
      failPlain('MISSING_SECTION', `required section heading not found: '${s}'`);
    }
  }
  if (hasBranchRecoveryRecord(kind)) {
    if (!headings.some((h) => h === BRANCH_RECOVERY_HEADING)) {
      failPlain('MISSING_SECTION', `required heading not found: '${BRANCH_RECOVERY_HEADING}'`);
    } else {
      const brFields = extractBranchRecoveryFields(text);
      for (const f of BRANCH_RECOVERY_FIELDS) {
        if (!fieldOk(brFields[f])) {
          failPlain('MISSING_BRANCH_RECOVERY_FIELD', `branch recovery record field '${f}' is missing, empty, or UNAVAILABLE without a reason`);
        }
      }
    }
  }

  // ---- manifests ----
  const manifests = loadManifests(repoRoot);
  const manifestEntries = allManifestEntries(manifests);

  // ---- (c)/(d) citation resolution ----
  const citations = scanCitations(text);
  for (const [citation, info] of citations) {
    if (info.isWordMention) {
      // bare "Lavish" mention with no .lavish/ or mock html path nearby on the line
      if (!lineHasMissingMarker(info.line)) {
        fail('MISSING_MOCKUP', `line ${info.lineIdx + 1} mentions "Lavish" without a resolvable artifact path or a MISSING EVIDENCE:/EXCLUDED: marker: "${info.line.trim()}"`);
      } else if (!markerExplanationOk(info.line)) {
        fail('MISSING_MOCKUP', `line ${info.lineIdx + 1} marks a Lavish reference missing/excluded but gives no custody explanation: "${info.line.trim()}"`);
      }
      continue;
    }
    if (lineHasMissingMarker(info.line)) {
      if (!markerExplanationOk(info.line)) {
        const tag = info.kind === 'mockup' ? 'MISSING_MOCKUP' : 'UNCOMMITTED_LOCAL_ARTIFACT';
        fail(tag, `line ${info.lineIdx + 1} marks '${citation}' missing/excluded but gives no custody explanation`);
      }
      continue; // explicitly marked with a real explanation -> satisfied
    }
    const entry = findManifestEntryForCitation(manifestEntries, citation);
    const tag = info.kind === 'mockup' ? 'MISSING_MOCKUP' : 'UNCOMMITTED_LOCAL_ARTIFACT';
    if (!entry) {
      fail(tag, `'${citation}' (line ${info.lineIdx + 1}) has no committed durable counterpart in any artifacts/**/MANIFEST.json and is not marked MISSING EVIDENCE:/EXCLUDED:`);
      continue;
    }
    if (EXCLUDED_STATUSES.has(entry.status) || !entry.agentlab_path) {
      fail(tag, `'${citation}' resolves to manifest entry with status ${entry.status} and no agentlab_path; must be marked EXCLUDED: in the checkpoint text with a custody explanation`);
      continue;
    }
    if (!DURABLE_STATUSES.has(entry.status)) {
      fail(tag, `'${citation}' resolves to manifest entry with unrecognised status '${entry.status}'`);
      continue;
    }
    const { rel: agentlabRel, abs: artifactAbs } = resolveAgentlabPath(repoRoot, entry.agentlab_path);
    if (!fs.existsSync(artifactAbs)) {
      fail(tag, `'${citation}' -> ${agentlabRel} is listed in manifest but missing from the working tree`);
      continue;
    }
    if (!args.workingTree && !trackedAtHead(repoRoot).has(agentlabRel.replace(/\\/g, '/'))) {
      fail(tag, `'${citation}' -> ${agentlabRel} exists on disk but is not tracked in 'git ls-tree HEAD'`);
      continue;
    }
    if (!args.workingTree && !args.offline) {
      const defaultRef = args.durableBranch ? `origin/${args.durableBranch}` : 'origin/main';
      const ok = sh(repoRoot, 'git', ['cat-file', '-e', `${defaultRef}:${agentlabRel}`]);
      if (ok === null) {
        fail(tag, `'${citation}' -> ${agentlabRel} is not reachable from ${defaultRef}`);
      }
    }
  }

  // ---- (e) decision references ----
  const { ids: citedDecisionIds, phraseHit } = scanDecisionRefs(text);
  if (citedDecisionIds.length > 0 || phraseHit) {
    const homeTaskMatch = relFilePath.match(/^checkpoints\/([^/]+)\/([^/]+)\//);
    let ledgerText = '';
    if (homeTaskMatch) {
      const ledgerPath = path.join(repoRoot, 'checkpoints', homeTaskMatch[1], homeTaskMatch[2], 'decisions.ledger.md');
      if (fs.existsSync(ledgerPath)) ledgerText = fs.readFileSync(ledgerPath, 'utf8');
    }
    const declared = ledgerDeclaredIds(ledgerText);
    // also allow a self-contained "## Decision ledger references" or any heading
    // containing "decision" to declare an id inline as `D-xx`.
    const selfSections = text.match(/##\s+(?:\d+\.\s+)?[^\n]*[Dd]ecision[^\n]*\n[\s\S]*?(?=\n##\s|$)/g) || [];
    const selfDeclared = new Set();
    for (const sec of selfSections) {
      const re = /\bD-\d+\b/g;
      let m;
      while ((m = re.exec(sec))) selfDeclared.add(m[0]);
    }
    for (const id of citedDecisionIds) {
      if (!declared.has(id) && !selfDeclared.has(id)) {
        fail('UNRECORDED_DECISION', `'${id}' is referenced but has no entry in decisions.ledger.md or the checkpoint's own decisions section`);
      }
    }
    if (phraseHit && citedDecisionIds.length === 0) {
      const hasDecisionSection = selfSections.some((sec) => sec.split('\n').slice(1).some((l) => l.trim() && l.trim() !== 'TODO'));
      if (!hasDecisionSection) {
        fail('UNRECORDED_DECISION', `"captain decided"/"captain ruling" is referenced but no populated decisions section or ledger id backs it`);
      }
    }
  }

  // ---- (f) SHA / PR resolution ----
  const shaSearchRoots = [args.appRepo ? path.resolve(args.appRepo) : null, repoRoot].filter(Boolean);
  for (const sha of scanShaRefs(text)) {
    let resolved = false;
    for (const root of shaSearchRoots) {
      if (sh(root, 'git', ['cat-file', '-e', sha]) !== null) { resolved = true; break; }
    }
    if (!resolved) {
      fail('UNRESOLVABLE_REFERENCE', `commit SHA '${sha}' does not resolve via 'git cat-file -e' in ${shaSearchRoots.join(' or ')}`);
    }
  }
  if (!args.offline) {
    for (const pr of scanPrRefs(text)) {
      let owner = pr.owner, repo = pr.repo;
      if (!owner) {
        const guess = gitRemoteOwnerRepo(args.appRepo ? path.resolve(args.appRepo) : repoRoot) || gitRemoteOwnerRepo(repoRoot);
        if (guess) { owner = guess.owner; repo = guess.repo; }
      }
      if (!owner || !repo) continue; // '#NNN' with no resolvable repo context: not enough info to check
      const out = sh(repoRoot, 'gh', ['api', `repos/${owner}/${repo}/pulls/${pr.num}`]);
      if (out === null) {
        fail('UNRESOLVABLE_REFERENCE', `PR reference '${pr.raw}' does not resolve via 'gh api repos/${owner}/${repo}/pulls/${pr.num}'`);
      }
    }
  }

  // ---- (g) artifact inventory vs MANIFEST.json vs repo blob ----
  const inventoryRows = findInventoryTables(text);
  for (const row of inventoryRows) {
    const entry = findManifestEntryForCitation(manifestEntries, row.path) ||
      manifestEntries.find((e) => (e.agentlab_path || '').endsWith(row.path) || row.path.endsWith(e.agentlab_path || '\u0000'));
    if (!entry) {
      fail('ARTIFACT_INVENTORY_MISMATCH', `inventory row '${row.path}' has no matching MANIFEST.json entry`);
      continue;
    }
    const manifestSha = entry.sha256_preserved || entry.sha256 || entry.sha256_original;
    if (row.sha256 && manifestSha && !manifestSha.startsWith(row.sha256.replace(/…$/, '')) && !row.sha256.startsWith(manifestSha.slice(0, row.sha256.length))) {
      fail('ARTIFACT_INVENTORY_MISMATCH', `inventory row '${row.path}' sha256 '${row.sha256}' does not match manifest sha256 '${manifestSha}'`);
    }
    if (entry.agentlab_path) {
      const { rel: agentlabRel, abs } = resolveAgentlabPath(repoRoot, entry.agentlab_path);
      if (fs.existsSync(abs) && !fs.statSync(abs).isDirectory()) {
        const actual = sha256File(abs);
        if (manifestSha && manifestSha.length >= 64 && actual !== manifestSha) {
          fail('ARTIFACT_INVENTORY_MISMATCH', `repo blob sha256 for ${agentlabRel} (${actual}) does not match MANIFEST.json (${manifestSha})`);
        }
      }
    }
  }

  // ---- (h) staleness ----
  const ckptTimestamp = header['Checkpoint timestamp'] ? new Date(header['Checkpoint timestamp']) : null;
  if (ckptTimestamp && !isNaN(ckptTimestamp.getTime())) {
    const homeTaskMatch = relFilePath.match(/^checkpoints\/([^/]+)\/([^/]+)\//);
    if (homeTaskMatch) {
      const ledgerPath = path.join(repoRoot, 'checkpoints', homeTaskMatch[1], homeTaskMatch[2], 'decisions.ledger.md');
      if (fs.existsSync(ledgerPath)) {
        const dates = ledgerEntryDates(fs.readFileSync(ledgerPath, 'utf8'));
        const newest = dates.sort((a, b) => b - a)[0];
        if (newest && ckptTimestamp < newest) {
          fail('STALE_CHECKPOINT', `checkpoint timestamp ${header['Checkpoint timestamp']} predates the newest decision ledger entry (${newest.toISOString()})`);
        }
      }
      const taskManifestPath = path.join(repoRoot, 'artifacts', homeTaskMatch[1], homeTaskMatch[2], 'MANIFEST.json');
      if (fs.existsSync(taskManifestPath)) {
        try {
          const md = JSON.parse(fs.readFileSync(taskManifestPath, 'utf8'));
          const mtimes = (md.entries || []).map((e) => new Date(e.mtime_utc)).filter((d) => !isNaN(d.getTime()));
          const newestM = mtimes.sort((a, b) => b - a)[0];
          if (newestM && ckptTimestamp < newestM) {
            fail('STALE_CHECKPOINT', `checkpoint timestamp ${header['Checkpoint timestamp']} predates the newest artifact in ${path.relative(repoRoot, taskManifestPath)} (${newestM.toISOString()})`);
          }
        } catch { /* malformed manifest already ignored above */ }
      }
    }
    if (!args.offline && args.appRepo && header['Current application branch'] && fieldOk(header['Current application branch']) && !header['Current application branch'].toUpperCase().startsWith('UNAVAILABLE')) {
      const remoteHead = sh(path.resolve(args.appRepo), 'git', ['rev-parse', header['Current application branch']]);
      const recordedHead = header['Current application head SHA'];
      if (remoteHead && recordedHead && fieldOk(recordedHead) && !recordedHead.toUpperCase().startsWith('UNAVAILABLE') && remoteHead !== recordedHead) {
        fail('STALE_CHECKPOINT', `recorded application head SHA (${recordedHead}) does not match current head of ${header['Current application branch']} in --app-repo (${remoteHead})`);
      }
    }
  }

  // ---- (i) pushed-ness ----
  const fileCommit = sh(repoRoot, 'git', ['log', '-1', '--format=%H', '--', relFilePath]);
  if (fileCommit) {
    if (!args.offline || args.requirePushed) {
      const defaultRef = args.durableBranch ? `origin/${args.durableBranch}` : 'origin/main';
      const hasRemote = sh(repoRoot, 'git', ['rev-parse', '--verify', defaultRef]);
      if (hasRemote) {
        const ancestor = sh(repoRoot, 'git', ['merge-base', '--is-ancestor', fileCommit, defaultRef]);
        // execFileSync throws (returns null via sh()) on non-zero exit, i.e. "not an ancestor"
        if (ancestor === null) {
          fail('NOT_PUSHED', `checkpoint's commit ${fileCommit.slice(0, 12)} is not reachable from ${defaultRef}`);
        }
      } else if (args.requirePushed) {
        fail('NOT_PUSHED', `cannot verify ${defaultRef} exists to confirm the checkpoint commit was pushed`);
      }
    }
  } else if (args.requirePushed) {
    fail('NOT_PUSHED', 'checkpoint file has no commit touching it yet');
  }

  // ---- (j) forbidden completion words ----
  const stateLineMatch = text.match(/##\s+State line\s*\n([\s\S]*?)(?:\n##\s|$)/i);
  const stateLineText = stateLineMatch ? stateLineMatch[1] : '';
  if (/\b(complete|done|handoff)\b/i.test(stateLineText)) {
    if (failures.length > 0) {
      failPlain('FORBIDDEN_COMPLETION_CLAIM', `state line uses complete/done/handoff while ${failures.length} other check(s) still fail`);
    }
  }

  if (failures.length === 0) {
    console.log(`PASS: ${filePath} (kind=${kind})`);
    process.exit(0);
  } else {
    for (const f of failures) console.log(f);
    console.log(`${failures.length} failure(s)`);
    process.exit(1);
  }
}

main();
