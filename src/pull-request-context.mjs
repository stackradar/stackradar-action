import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const shaPattern = /^[a-f0-9]{40}$/;

export function pullRequestContext(event, environment, git) {
  if (environment.GITHUB_EVENT_NAME !== 'pull_request') {
    if (environment.GITHUB_EVENT_NAME !== 'push' || environment.GITHUB_REF !== `refs/heads/${event.repository?.default_branch}`) {
      throw new Error('Only default-branch pushes and same-repository pull requests are supported.');
    }
    return null;
  }

  const pr = event.pull_request;
  const repositoryId = String(event.repository?.id ?? '');
  if (!pr || !Number.isSafeInteger(event.number) || event.number < 1 || !/^[1-9][0-9]*$/.test(repositoryId)
    || String(pr.head?.repo?.id) !== repositoryId || String(pr.base?.repo?.id) !== repositoryId
    || repositoryId !== environment.GITHUB_REPOSITORY_ID
    || environment.GITHUB_REF !== `refs/pull/${event.number}/merge`
    || pr.base?.ref !== event.repository.default_branch
    || environment.GITHUB_ACTOR === 'dependabot[bot]' || pr.user?.login === 'dependabot[bot]'
    || !shaPattern.test(pr.head?.sha) || !shaPattern.test(pr.base?.sha)) {
    throw new Error('Unsupported or invalid pull request context. Forks and Dependabot PRs cannot upload evidence.');
  }
  if (git(['rev-parse', 'HEAD']) !== pr.head.sha) {
    throw new Error('Checkout must match the PR head, not the synthetic merge commit.');
  }

  const branchPoints = git(['merge-base', '--all', pr.head.sha, pr.base.sha]).split('\n');
  if (branchPoints.length !== 1 || !shaPattern.test(branchPoints[0])) {
    throw new Error('Cannot establish an unambiguous PR branch point.');
  }
  const branchPoint = branchPoints[0];
  const history = git(['rev-list', '--max-count=1000', '--ancestry-path', `${branchPoint}..${pr.base.sha}`]);
  const eligible = history ? history.split('\n') : [];
  // If the bounded window is full, older snapshots are intentionally inconclusive.
  if (eligible.length < 1000) eligible.push(branchPoint);
  if (!eligible.every((sha) => shaPattern.test(sha))) throw new Error('Invalid Git history.');

  return {
    number: event.number,
    head_sha: pr.head.sha,
    base_sha: pr.base.sha,
    head_repository_id: repositoryId,
    baseline_eligible_shas: eligible,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const context = pullRequestContext(event, process.env, (args) => execFileSync('git', args, {
    cwd: process.env.GITHUB_WORKSPACE,
    encoding: 'utf8',
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1', GIT_TERMINAL_PROMPT: '0' },
    maxBuffer: 1024 * 1024,
  }).trim());
  if (context) {
    const directory = mkdtempSync(join(process.env.RUNNER_TEMP, 'stackradar-pr-'));
    const path = join(directory, 'context.json');
    writeFileSync(path, JSON.stringify(context), { mode: 0o600 });
    appendFileSync(process.env.GITHUB_OUTPUT, `path=${path}\n`);
  }
}
