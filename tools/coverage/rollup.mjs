// Behaviour-note coverage roll-up (docs/plan-notes.md, workstream Q).
//
//   node tools/coverage/rollup.mjs            rewrite the table in docs/milestones.md
//   node tools/coverage/rollup.mjs --check    exit 1 if the table is out of date
//   node tools/coverage/rollup.mjs --seed     create docs/coverage/<note>.md for
//                                             notes that have none (all rows todo)
//
// Each behaviour note's numbered rules are its "### N.M Title" headings.
// docs/coverage/<note>.md has one table row per rule:
//
//   | rule | status | test | notes |
//   | 3.1 Turning (player) | done | sim/test/bodies_turn.zig | |
//
// status is one of: done, ours (done with our own numbers where the note is
// silent), stubbed (API exists, does nothing yet), blocked (waits on a
// missing note), todo. A rule with no row counts as todo; a row whose rule
// is not in the note is reported as stale.
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const notesDir = join(root, 'docs', 'behaviour');
const covDir = join(root, 'docs', 'coverage');
const milestones = join(root, 'docs', 'milestones.md');
const statuses = ['done', 'ours', 'stubbed', 'blocked', 'todo'];
const begin = '<!-- coverage:begin (tools/coverage/rollup.mjs) -->';
const end = '<!-- coverage:end -->';

const args = process.argv.slice(2);
const notes = readdirSync(notesDir)
  .filter((f) => f.endsWith('.md') && f === f.toLowerCase() && !['readme.md'].includes(f.toLowerCase()))
  .filter((f) => !/^[A-Z_]+\.md$/.test(f))
  .sort();

// Rules: numbered "N.M Title" headings; a note without them (car-handling)
// uses the unnumbered "### Title" headings of its section 3, keyed by title.
function rulesOf(file) {
  const numbered = [];
  const plain = [];
  let section = '';
  for (const line of readFileSync(join(notesDir, file), 'utf8').split('\n')) {
    const sec = /^##\s+(\d+)\./.exec(line);
    if (sec) section = sec[1];
    const m = /^#{2,4}\s+(\d+\.\d+)\s+(.*)$/.exec(line);
    if (m) numbered.push({ id: m[1], title: m[2].trim() });
    else if (section === '3' && /^###\s+/.test(line)) {
      const title = line.replace(/^###\s+/, '').trim();
      plain.push({ id: title, title: '' });
    }
  }
  return numbered.length ? numbered : plain;
}

function rowsOf(file) {
  const p = join(covDir, file);
  if (!existsSync(p)) return null;
  const rows = new Map();
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const cells = line.split('|').slice(1, -1).map((c) => c.trim());
    if (cells.length < 2) continue;
    if (cells[0] === 'rule' || /^-+$/.test(cells[0])) continue;
    const m = /^(\d+\.\d+)\b/.exec(cells[0]);
    const st = cells[1].toLowerCase();
    rows.set(m ? m[1] : cells[0], { status: statuses.includes(st) ? st : 'todo', bad: !statuses.includes(st), test: cells[2] ?? '' });
  }
  return rows;
}

if (args.includes('--seed')) {
  mkdirSync(covDir, { recursive: true });
  for (const f of notes) {
    const p = join(covDir, f);
    if (existsSync(p)) continue;
    const name = f.replace(/\.md$/, '');
    let s = `# Coverage: ${name}\n\nRules from [docs/behaviour/${f}](../behaviour/${f}). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.\n\n| rule | status | test | notes |\n|---|---|---|---|\n`;
    for (const r of rulesOf(f)) s += `| ${`${r.id} ${r.title}`.trim()} | todo | | |\n`;
    writeFileSync(p, s);
    console.log('seeded', p);
  }
}

let table = `${begin}\n\n| note | rules | done | ours | stubbed | blocked | todo | no file / stale rows |\n|---|---:|---:|---:|---:|---:|---:|---|\n`;
const total = Object.fromEntries(statuses.map((s) => [s, 0]));
let totalRules = 0;
const problems = [];
for (const f of notes) {
  const rules = rulesOf(f);
  const rows = rowsOf(f);
  const n = Object.fromEntries(statuses.map((s) => [s, 0]));
  for (const r of rules) {
    const row = rows?.get(r.id);
    n[row ? row.status : 'todo'] += 1;
    if (row?.bad) problems.push(`${f}: rule ${r.id} has an unknown status`);
  }
  const stale = rows ? [...rows.keys()].filter((k) => !rules.some((r) => r.id === k)) : [];
  for (const s of statuses) total[s] += n[s];
  totalRules += rules.length;
  const note = rows ? (stale.length ? `stale: ${stale.join(', ')}` : '') : 'no coverage file';
  const name = f.replace(/\.md$/, '');
  const link = rows ? `[${name}](coverage/${f})` : name;
  table += `| ${link} | ${rules.length} | ${n.done} | ${n.ours} | ${n.stubbed} | ${n.blocked} | ${n.todo} | ${note} |\n`;
}
table += `| **all notes** | **${totalRules}** | **${total.done}** | **${total.ours}** | **${total.stubbed}** | **${total.blocked}** | **${total.todo}** | |\n\n${end}`;

const md = readFileSync(milestones, 'utf8');
let next;
if (md.includes(begin)) {
  next = md.slice(0, md.indexOf(begin)) + table + md.slice(md.indexOf(end) + end.length);
} else {
  next = md.trimEnd() + `\n\n## Behaviour note coverage\n\nRolled up from \`docs/coverage/\` by \`node tools/coverage/rollup.mjs\`. A rule is a numbered "N.M" heading in its note.\n\n${table}\n`;
}
for (const p of problems) console.error(p);
if (args.includes('--check')) {
  if (next !== md) { console.error('docs/milestones.md coverage table is out of date: run node tools/coverage/rollup.mjs'); process.exit(1); }
  console.log('coverage table up to date');
} else {
  writeFileSync(milestones, next);
  console.log(`rules ${totalRules}: ${statuses.map((s) => `${s} ${total[s]}`).join(', ')}`);
}
