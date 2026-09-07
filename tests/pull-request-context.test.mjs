import { strict as assert } from 'node:assert';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
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
const fakeGit = (args) => args[0] === 'rev-parse' ? head : args[0] === 'merge-base' ? point : base;

test('derives head and verified baseline window without treating merge SHA as head', () => {
  const { event, env } = fixture();
  assert.deepEqual(pullRequestContext(event, env, fakeGit), { number: 447, head_sha: head, base_sha: base, head_repository_id: '123', baseline_eligible_shas: [base, point] });
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

test('uses real ancestry and excludes snapshots older than the PR branch point', (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'stackradar-history-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const git = (args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git(['init', '-b', 'trunk']); git(['config', 'user.name', 'Tests']); git(['config', 'user.email', 'tests@stackradar.com']);
  git(['commit', '--allow-empty', '-m', 'old']); const old = git(['rev-parse', 'HEAD']);
  git(['commit', '--allow-empty', '-m', 'branch point']); const branchPoint = git(['rev-parse', 'HEAD']);
  git(['checkout', '-b', 'feature']); git(['commit', '--allow-empty', '-m', 'head']); const prHead = git(['rev-parse', 'HEAD']);
  git(['checkout', 'trunk']); git(['commit', '--allow-empty', '-m', 'base']); const prBase = git(['rev-parse', 'HEAD']);
  git(['checkout', '--detach', prHead]);
  const { event, env } = fixture(); event.pull_request.head.sha = prHead; event.pull_request.base.sha = prBase;
  const context = pullRequestContext(event, env, git);
  assert.deepEqual(context.baseline_eligible_shas, [prBase, branchPoint]);
  assert.ok(!context.baseline_eligible_shas.includes(old));
});

test('bounds history and rejects ambiguous branch points', () => {
  const { event, env } = fixture();
  const commits = Array.from({ length: 1000 }, (_, i) => i.toString(16).padStart(40, '0'));
  const context = pullRequestContext(event, env, (args) => args[0] === 'rev-list' ? commits.join('\n') : fakeGit(args));
  assert.equal(context.baseline_eligible_shas.length, 1000);
  assert.throws(() => pullRequestContext(event, env, (args) => args[0] === 'merge-base' ? `${point}\n${base}` : fakeGit(args)));
});
