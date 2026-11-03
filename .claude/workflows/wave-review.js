export const meta = {
  name: 'wave-review',
  description: 'Review a wave: reviewer on every task, security-reviewer where flagged; returns ledger lines',
  whenToUse: 'Started by the /wave-review skill with review packages already written; not for implementers or fix rounds that need follow-up messages',
  phases: [
    { title: 'Review', detail: 'reviewer per task, plus security-reviewer where the task is flagged' },
  ],
}

// args: { tasks: [{ id, package, report?, security?, kind? }] }
//   package: path from the review-package skill; report: the implementer's report file
//   kind: 'review' (default) or 're-review'; decides the ledger line's verb
const tasks = (args && args.tasks) || []
if (!tasks.length) throw new Error('wave-review: args.tasks is empty; pass [{id, package, security}]')
for (const t of tasks) {
  if (!t.id || !t.package) throw new Error(`wave-review: task ${JSON.stringify(t)} needs id and package`)
}

const FINDINGS = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['Approved', 'Needs fixes'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          tag: { type: 'string', enum: ['MUST-FIX', 'SHOULD-FIX', 'CONSIDER'] },
          checklist: { type: 'integer', description: 'review-checklist.md class number, 0 if none' },
          file: { type: 'string' },
          line: { type: 'integer' },
          defect: { type: 'string' },
          recommendation: { type: 'string' },
          hypothesis: { type: 'boolean', description: 'true if not confirmed' },
        },
        required: ['tag', 'file', 'defect', 'recommendation'],
      },
    },
    ran: { type: 'string', description: 'what you ran or read' },
    residual: { type: 'string', description: 'residual risk, or "no blocking issues"' },
  },
  required: ['verdict', 'findings', 'ran', 'residual'],
}

const seats = tasks.flatMap(t =>
  [{ t, reviewer: 'reviewer' }].concat(t.security ? [{ t, reviewer: 'security-reviewer' }] : []))
log(`${tasks.length} tasks, ${seats.length} review seats (${seats.length - tasks.length} security)`)

phase('Review')
const results = await parallel(seats.map(({ t, reviewer }) => () =>
  agent(
    `Review task ${t.id}. The diff, commit list and stat are in ${t.package}; read that file first.` +
      (t.report ? ` The implementer's report is ${t.report}.` : '') +
      ` Run docs/superpowers/review-checklist.md over the diff and put the class number on each finding.` +
      ` Return every finding; the controller rules on them.`,
    { label: `${reviewer} ${t.id}`, phase: 'Review', agentType: reviewer, schema: FINDINGS })
    .then(r => ({ t, reviewer, r }))))

// A seat that died returns null from agent(); it is listed, never counted as Approved.
// Results come back as copies, so seats match by id and reviewer, not object identity.
const count = (fs, tag) => fs.filter(f => f.tag === tag).length
const done = results.filter(x => x && x.r)
const uncovered = seats
  .filter(s => !done.some(d => d.t.id === s.t.id && d.reviewer === s.reviewer))
  .map(s => `${s.t.id} (${s.reviewer})`)
if (uncovered.length) log(`Not covered: ${uncovered.join(', ')}`)

return {
  ledger: done.map(({ t, reviewer, r }) =>
    `Task ${t.id} ${t.kind === 're-review' ? 're-review' : 'review'} (${reviewer}): ${r.verdict}; ` +
    `MUST-FIX ${count(r.findings, 'MUST-FIX')}; SHOULD-FIX ${count(r.findings, 'SHOULD-FIX')}; ` +
    `CONSIDER ${count(r.findings, 'CONSIDER')}`),
  reviews: done.map(({ t, reviewer, r }) => ({ task: t.id, reviewer, ...r })),
  uncovered,
}
