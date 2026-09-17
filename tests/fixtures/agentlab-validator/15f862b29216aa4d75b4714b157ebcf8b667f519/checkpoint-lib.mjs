#!/usr/bin/env node
// Single source of truth for checkpoint structure: header blocks, required
// section headings per checkpoint kind, and the branch-recovery-record
// fields. Both scripts/checkpoint-template.sh (via `node checkpoint-lib.mjs
// template <kind>`) and scripts/validate-checkpoint.mjs import this module,
// so the printed template and the validator's requirements can never drift
// apart. See docs/evidence-preservation-lifecycle.md for the contract these
// encode (captain's directive sections 2, 4, 5, 6, 7).

export const KINDS = ['initial', 'update', 'final', 'crew-report'];

// Directive section 7: FirstMate block (initial/update/final checkpoints).
export const FIRSTMATE_HEADER_FIELDS = [
  'FirstMate model',
  'FirstMate Claude session ID',
  'FirstMate resume URL',
  'Initial session start',
  'Checkpoint timestamp',
  'Application repository',
  'AgentLab report commit',
  'Current application branch',
  'Current application head SHA',
  'Associated PRs',
];

// Directive section 7: crew block (crew-report checkpoints).
export const CREW_HEADER_FIELDS = [
  'Crew role/name',
  'Crew task',
  'Crew model',
  'Crew Claude session ID',
  'Crew resume URL',
  'Supervising FirstMate session ID',
  'Supervising FirstMate resume URL',
  'Application branch/head',
  'AgentLab artifact/report paths',
];

export function headerFieldsForKind(kind) {
  return kind === 'crew-report' ? CREW_HEADER_FIELDS : FIRSTMATE_HEADER_FIELDS;
}

// Directive section 4: bounded branch recovery record, embedded in every
// checkpoint (initial/update/final) under this fixed heading.
export const BRANCH_RECOVERY_HEADING = 'Branch recovery record';

export const BRANCH_RECOVERY_FIELDS = [
  'Repository',
  'Base branch',
  'Working branch',
  'Base SHA',
  'Current head SHA',
  'Merge base',
  'Associated PR number and URL',
  'Clean/dirty status',
  'Changed-file inventory',
  'Untracked-file inventory',
  'Worktree path (historical context, non-durable)',
  'Commit list introduced by the branch',
  'Files created, changed, deleted or intentionally left local',
  'Current CI/check status',
  'Deployment state',
  'Database/migration state',
  'Known divergence or rebase requirements',
  'Exact safe continuation command or procedure',
  'Artifacts belonging to this branch',
  'Local-only artifacts already copied into AgentLab',
];

// Directive section 5: continuous-checkpoint (update kind) must distinguish
// exactly these six things.
export const UPDATE_DISTINCTIONS = [
  'Previously approved state',
  'New information',
  'Superseded decision or requirement',
  'Current authoritative decision',
  'Remaining uncertainty',
  'Exact files/artifacts added or updated',
];

// Directive section 2: initial checkpoint, 15 named contents.
export const INITIAL_SECTIONS = [
  'Detailed problem statement and verified current state',
  'All evidence sources inspected',
  'Every decision already made by the captain',
  'Requirements agreed with the captain (exact wording where it materially controls implementation)',
  'Rejected alternatives and why they were rejected',
  'Open decisions genuinely requiring the captain',
  'Scope boundaries and explicit exclusions',
  'Risks, assumptions and unresolved uncertainties',
  'Implementation slices and their intended sequence',
  'Relevant branch, worktree and repository state', // BRANCH_RECOVERY_HEADING satisfies this
  'All generated mock-ups and design artifacts',
  'Complete artifact/file inventory',
  'FirstMate Claude resume-session ID and direct resume URL', // header block satisfies this
  "Every participating crew member's identity, task and resume-session ID where available",
  'Links to related PRs, commits, issues and deployment evidence',
];

// Directive section 6: pre-teardown final checkpoint, 18 named contents.
export const FINAL_SECTIONS = [
  'Complete detailed summary of work performed',
  'Final current state',
  "Every captain decision made during the agent's lifetime",
  'The latest agreed requirements',
  'Superseded requirements and their replacements',
  'All mock-ups and their versions',
  'All Lavish source/output files',
  'Branch/tree/worktree recovery manifest', // BRANCH_RECOVERY_HEADING satisfies this
  'PRs, commits, exact SHAs and merge state',
  'CI, test and review evidence',
  'Deployment and database state',
  'Remaining blockers and next actions',
  'Exact continuation instructions',
  'FirstMate resume-session ID and URL again', // header block satisfies this
  'Crew resume-session IDs and task ownership',
  'Artifact inventory with GitHub paths, hashes and status',
  'Explicit confirmation that no cited local artifact remains unpreserved',
  'Explicit list of anything that could not be preserved and why',
];

// crew-report: the crew-facing counterpart. Not directly numbered by the
// directive (sections 2/6 are FirstMate checkpoints); this mirrors their
// substance for a single crew member's report, per section 7's crew block
// and section 9's "identify task, artifacts, gap report" requirements.
export const CREW_REPORT_SECTIONS = [
  'Work performed this run',
  'Every decision or requirement this crew member relied on (with ledger/section reference)',
  'Mock-ups or artifacts produced or modified',
  'Artifact inventory with AgentLab paths',
  'Branch/head state at handoff',
  'Remaining blockers and next actions',
  'Confirmation that no cited local artifact remains unpreserved',
];

export function sectionsForKind(kind) {
  switch (kind) {
    case 'initial': return INITIAL_SECTIONS;
    case 'update': return UPDATE_DISTINCTIONS;
    case 'final': return FINAL_SECTIONS;
    case 'crew-report': return CREW_REPORT_SECTIONS;
    default: throw new Error(`unknown checkpoint kind: ${kind}`);
  }
}

export function hasBranchRecoveryRecord(kind) {
  return kind === 'initial' || kind === 'update' || kind === 'final';
}

function headerBlockMarkdown(kind) {
  const fields = headerFieldsForKind(kind);
  return fields.map((f) => `${f}:`).join('\n');
}

function branchRecoveryMarkdown() {
  const lines = [`## ${BRANCH_RECOVERY_HEADING}`, ''];
  for (const f of BRANCH_RECOVERY_FIELDS) lines.push(`- ${f}: `);
  return lines.join('\n');
}

export function renderTemplate(kind) {
  if (!KINDS.includes(kind)) {
    throw new Error(`unknown checkpoint kind '${kind}'; expected one of ${KINDS.join(', ')}`);
  }
  const title = kind === 'crew-report' ? 'AgentLab crew report' : `AgentLab ${kind} checkpoint`;
  const out = [];
  out.push(`# ${title}`);
  out.push('');
  out.push('<!-- Every field below is required by docs/evidence-preservation-lifecycle.md');
  out.push('     and scripts/validate-checkpoint.mjs. If a value is genuinely unavailable,');
  out.push('     write UNAVAILABLE followed by the reason on the same line -- never leave a');
  out.push('     required field silently blank or delete the field. -->');
  out.push('');
  out.push('## Session identification');
  out.push('');
  out.push('```text');
  out.push(headerBlockMarkdown(kind));
  out.push('```');
  out.push('');
  if (hasBranchRecoveryRecord(kind)) {
    out.push(branchRecoveryMarkdown());
    out.push('');
  }
  const sections = sectionsForKind(kind);
  sections.forEach((heading, i) => {
    out.push(`## ${i + 1}. ${heading}`);
    out.push('');
    out.push('TODO');
    out.push('');
  });
  if (kind === 'initial' || kind === 'update' || kind === 'final') {
    out.push('## Decision ledger references');
    out.push('');
    out.push('<!-- Every `decision D-xx` / "captain decided" / "captain ruling" mentioned');
    out.push('     above must appear here with its ledger id, or in');
    out.push('     checkpoints/<home>/<task-id>/decisions.ledger.md -->');
    out.push('');
    out.push('TODO');
    out.push('');
  }
  out.push('## State line');
  out.push('');
  out.push('<!-- Must not contain complete/done/handoff unless checks (a)-(i) all pass. -->');
  out.push('');
  out.push('TODO');
  out.push('');
  return out.join('\n');
}

// Allow `node checkpoint-lib.mjs template <kind>` for scripts/checkpoint-template.sh.
if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, kind] = process.argv.slice(2);
  if (cmd === 'template' && kind) {
    process.stdout.write(renderTemplate(kind) + '\n');
  } else {
    console.error('usage: node checkpoint-lib.mjs template <initial|update|final|crew-report>');
    process.exit(2);
  }
}
