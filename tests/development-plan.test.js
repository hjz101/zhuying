import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');
const plan = read('../docs/DEVELOPMENT-PLAN.md');
const features = read('../ios/FEATURES.md');
const prd = read('../docs/PRD.md');

function tableRows(markdown) {
  return markdown.split('\n')
    .filter(line => line.startsWith('| '))
    .map(line => line.split('|').slice(1, -1).map(cell => cell.trim()));
}

const taskRefs = text => text.match(/\bT\d{3}\b/g) ?? [];

function parseTasks(markdown) {
  return tableRows(markdown).filter(row => /^\[[ x]\] T\d{3}$/.test(row[0]))
    .map(([label, priority, work, prerequisites, reason, acceptance, ...extra]) => ({
      id: label.slice(4), priority, work, dependencies: taskRefs(prerequisites), reason,
      acceptance, prerequisites, extra
    }));
}

function validateGraph(tasks) {
  const byID = new Map(tasks.map(task => [task.id, task]));
  assert.equal(byID.size, tasks.length, 'task IDs must be unique');
  const visiting = new Set();
  const visited = new Set();
  function visit(id) {
    assert.ok(byID.has(id), `unknown prerequisite ${id}`);
    assert.ok(!visiting.has(id), `dependency cycle at ${id}`);
    if (visited.has(id)) return;
    visiting.add(id);
    for (const dependency of byID.get(id).dependencies) visit(dependency);
    visiting.delete(id);
    visited.add(id);
  }
  for (const task of tasks) visit(task.id);
  return byID;
}

const tasks = parseTasks(plan);
const featureRows = tableRows(plan).filter(row => /^F\d{2}$/.test(row[0]));
const acceptanceRows = tableRows(plan).filter(row => /^AC-\d{2}$/.test(row[0]));
const gates = tableRows(plan).filter(row => /^G\d$/.test(row[0]));

function closure(byID, roots) {
  const result = new Set();
  function add(id) {
    assert.ok(byID.has(id), `unknown gate task ${id}`);
    if (result.has(id)) return;
    result.add(id);
    for (const dependency of byID.get(id).dependencies) add(dependency);
  }
  roots.forEach(add);
  return result;
}

test('development plan covers every original feature exactly once and names real tasks', () => {
  const sourceSection = features.split('## 覆盖清单')[1].split('## 模拟边界')[0];
  const names = tableRows(sourceSection).slice(2).map(row => row[0]);
  assert.equal(names.length, 47);
  assert.deepEqual(featureRows.map(row => row[1]), names);
  const byID = validateGraph(tasks);
  featureRows.forEach(([id, name, path, scope], index) => {
    assert.equal(id, `F${String(index + 1).padStart(2, '0')}`);
    assert.ok(scope, `${name} needs a delivery scope`);
    const refs = taskRefs(path);
    assert.ok(refs.length > 0, `${name} needs implementation tasks`);
    for (const ref of refs) assert.ok(byID.has(ref), `${name} references ${ref}`);
  });
});

test('each scheduled task has a priority, work, prerequisites, rationale and acceptance', () => {
  assert.equal(tasks.length, 72);
  tasks.forEach((task, index) => {
    assert.equal(task.id, `T${String(index + 1).padStart(3, '0')}`);
    assert.ok(['P0', 'P0-C', 'P1', 'P2'].includes(task.priority), task.id);
    for (const key of ['work', 'reason', 'acceptance']) {
      assert.ok(task[key]?.length >= 10, `${task.id} needs meaningful ${key}`);
    }
    assert.equal(task.extra.length, 0, `${task.id} has malformed table columns`);
    const expected = task.dependencies.length ? task.dependencies.join('、') : '—';
    assert.equal(task.prerequisites, expected, `${task.id} prerequisites must be explicit`);
    assert.equal(new Set(task.dependencies).size, task.dependencies.length);
  });
});

test('task dependencies are acyclic and early releases do not require later-priority tasks', () => {
  const byID = validateGraph(tasks);
  const rank = { P0: 0, 'P0-C': 0, P1: 1, P2: 2 };
  for (const task of tasks) {
    for (const dependency of task.dependencies) {
      assert.ok(rank[byID.get(dependency).priority] <= rank[task.priority],
        `${task.id} is blocked by later-priority ${dependency}`);
    }
  }
});

test('release gates include every task promised for their release', () => {
  const byID = validateGraph(tasks);
  assert.deepEqual(gates.map(row => row[0]), ['G0', 'G1', 'G2', 'G3', 'G4', 'G5']);
  const reached = new Map(gates.map(([id, refs, result]) => {
    assert.ok(result?.length >= 10, `${id} needs a concrete outcome`);
    return [id, closure(byID, taskRefs(refs))];
  }));
  for (const task of tasks) {
    if (task.priority === 'P0' || task.priority === 'P0-C') {
      assert.ok(reached.get('G3').has(task.id), `first release omits ${task.id}`);
    }
    if (task.priority === 'P1') {
      assert.ok(reached.get('G4').has(task.id), `second release omits ${task.id}`);
    }
    assert.ok(reached.get('G5').has(task.id), `full release omits ${task.id}`);
  }
});

test('all original acceptance criteria map to tasks reachable by the first release', () => {
  const expected = [...new Set(tableRows(prd).map(row => row[0]).filter(id => /^AC-\d{2}$/.test(id)))];
  assert.equal(expected.length, 19);
  assert.deepEqual(acceptanceRows.map(row => row[0]), expected);
  const byID = validateGraph(tasks);
  const firstRelease = closure(byID, taskRefs(gates.find(row => row[0] === 'G3')[1]));
  for (const [id, refs, outcome] of acceptanceRows) {
    assert.ok(outcome?.length >= 10, `${id} needs an expected result`);
    assert.ok(taskRefs(refs).length > 0, `${id} needs test ownership`);
    for (const ref of taskRefs(refs)) {
      assert.ok(firstRelease.has(ref), `${id} references ${ref} outside first release`);
    }
  }
});

test('parallel entry tasks only depend on the contracts and samples available at kickoff', () => {
  const byID = validateGraph(tasks);
  const expectPrerequisites = (id, dependencies) => assert.deepEqual(byID.get(id).dependencies, dependencies);
  expectPrerequisites('T002', ['T001']);
  expectPrerequisites('T003', ['T001']);
  expectPrerequisites('T004', ['T001']);
  expectPrerequisites('T006', ['T002', 'T004']);
  expectPrerequisites('T013', ['T004']);
  expectPrerequisites('T017', ['T004']);
  expectPrerequisites('T021', ['T003', 'T004']);
  const localMilestone = closure(byID, ['T020']);
  for (const onlineTask of ['T003', 'T021', 'T022', 'T023', 'T025', 'T028', 'T030']) {
    assert.ok(!localMilestone.has(onlineTask), `local milestone waits for ${onlineTask}`);
  }
  assert.ok(!closure(byID, ['T023']).has('T006'), 'source adapter waits for database implementation');
});

test('dependency validation rejects missing tasks, duplicate IDs and circular schedules', () => {
  const task = (id, dependencies = []) => ({ id, dependencies });
  assert.throws(() => validateGraph([task('T001', ['T999'])]), /unknown prerequisite/);
  assert.throws(() => validateGraph([task('T001'), task('T001')]), /unique/);
  assert.throws(() => validateGraph([task('T001', ['T002']), task('T002', ['T001'])]), /cycle/);
  assert.throws(() => validateGraph([task('T001', ['T001'])]), /cycle/);
});
