import { strict as assert } from 'node:assert';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, renameSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { pullRequestContext } from '../src/pull-request-context.mjs';

const head = 'a'.repeat(40);
const base = 'b'.repeat(40);
const point = 'c'.repeat(40);
function fixture() {
  return {
    event: { number: 447, repository: { id: 123, default_branch: 'trunk' }, pull_request: { head: { sha: head, repo: { id: 123 } }, base: { sha: base, ref: 'trunk', repo: { id: 123 } }, user: { login: 'renovate[bot]' } } },
    env: { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REPOSITORY_ID: '123', GITHUB_REF: 'refs/pull/447/merge', GITHUB_ACTOR: 'renovate[bot]' },
  };
}
const fakeGit = (args) => args[0] === 'rev-parse' ? head : args[0] === 'merge-base' ? point : '';

test('derives exact head and changed paths without a baseline ancestry window', () => {
  const { event, env } = fixture();
  assert.deepEqual(pullRequestContext(event, env, fakeGit), { number: 447, head_sha: head, base_sha: base, head_repository_id: '123', changed_files: [] });
});

test('rejects unsupported origins, targets, event numbers and checkouts', () => {
  for (const mutate of [
    (f) => { f.event.pull_request.head.repo.id = 999; },
    (f) => { f.event.pull_request.base.ref = 'release'; },
    (f) => { f.env.GITHUB_ACTOR = 'dependabot[bot]'; },
    (f) => { f.event.pull_request.user.login = 'dependabot[bot]'; },
    (f) => { f.env.GITHUB_EVENT_NAME = 'pull_request_target'; },
    (f) => { f.env.GITHUB_REF = 'refs/pull/448/merge'; },
    (f) => { f.event.pull_request.head.sha = '--help'; },
    (f) => { f.event.pull_request.head.sha = base; },
  ]) {
    const f = fixture(); mutate(f);
    assert.throws(() => pullRequestContext(f.event, f.env, fakeGit));
  }
});

test('only default branch pushes produce inventory', () => {
  const { event, env } = fixture();
  env.GITHUB_EVENT_NAME = 'push'; env.GITHUB_REF = 'refs/heads/trunk';
  assert.equal(pullRequestContext(event, env, fakeGit), null);
  env.GITHUB_REF = 'refs/heads/feature';
  assert.throws(() => pullRequestContext(event, env, fakeGit));
});

test('collects real PR changes including deletion and rename, excluding changes only on main', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'stackradar-history-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const git = (args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  git(['init', '-b', 'trunk']); git(['config', 'user.name', 'Tests']); git(['config', 'user.email', 'tests@stackradar.com']);
  writeFileSync(join(directory, 'package-lock.json'), 'lock');
  writeFileSync(join(directory, 'old requirements.txt'), 'example==1.0');
  git(['add', '.']); git(['commit', '-m', 'base']);
  git(['checkout', '-b', 'feature']);
  unlinkSync(join(directory, 'package-lock.json'));
  renameSync(join(directory, 'old requirements.txt'), join(directory, 'requirements.txt'));
  writeFileSync(join(directory, 'package.json'), '{}');
  git(['add', '.']); git(['commit', '-m', 'PR']); const prHead = git(['rev-parse', 'HEAD']).trim();
  git(['checkout', 'trunk']); writeFileSync(join(directory, 'composer.json'), '{}');
  git(['add', '.']); git(['commit', '-m', 'main only']); const prBase = git(['rev-parse', 'HEAD']).trim();
  git(['checkout', '--detach', prHead]);
  const { event, env } = fixture(); event.pull_request.head.sha = prHead; event.pull_request.base.sha = prBase;
  assert.deepEqual(pullRequestContext(event, env, git).changed_files, [
    { path: 'package-lock.json', status: 'removed' },
    { path: 'package.json', status: 'added' },
    { path: 'requirements.txt', status: 'renamed', previous_path: 'old requirements.txt' },
  ]);
});

test('rejects ambiguous branch points and incomplete changed-file lists', () => {
  const { event, env } = fixture();
  assert.throws(() => pullRequestContext(event, env, (args) => args[0] === 'merge-base' ? `${point}\n${base}` : fakeGit(args)));
  assert.throws(() => pullRequestContext(event, env, (args) => args[0] === 'diff' ? 'R100\0old\0' : fakeGit(args)));
  assert.throws(() => pullRequestContext(event, env, (args) => args[0] === 'diff' ? 'M\0truncated' : fakeGit(args)));
});
