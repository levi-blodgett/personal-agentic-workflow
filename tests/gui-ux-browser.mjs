#!/usr/bin/env node
// Isolated recorded-evidence browser regression. Uses Node's built-in WebSocket/CDP.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, realpathSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const checkout = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const chromePath = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
assert.equal(typeof WebSocket, 'function', 'Use Node 22+ with built-in WebSocket');
const version = execFileSync(chromePath, ['--version'], { encoding: 'utf8' }).trim();
const root = realpathSync(mkdtempSync(join(tmpdir(), 'paw-validation-browser-')));
const repo = join(root, 'one', 'repo');
const secondRepo = join(root, 'two', 'repo');
const evidence = process.env.PAW_GUI_EVIDENCE;
const baseline = process.argv.includes('--baseline');
if (evidence) mkdirSync(evidence, { recursive: true });
const task = join(repo, '.agent/checks');
const profile = join(root, 'chrome');
const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('PAW_')));
Object.assign(environment, { XDG_STATE_HOME: join(root, 'state'), PYTHONDONTWRITEBYTECODE: '1' });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const children = [];
let socket;

async function until(description, predicate) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await sleep(100);
  }
  throw new Error(`Timed out: ${description}`);
}

function launch(command, args) {
  const child = spawn(command, args, { env: environment, stdio: ['ignore', 'pipe', 'pipe'] });
  child.output = '';
  child.errors = '';
  child.stdout.on('data', chunk => { child.output += chunk; });
  child.stderr.on('data', chunk => { child.errors += chunk; });
  child.on('error', error => { child.errors += error.message; });
  children.push(child);
  return child;
}

async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  for (let attempt = 0; attempt < 50; attempt++) {
    if (child.exitCode !== null || child.signalCode !== null) return;
    await sleep(100);
  }
  child.kill('SIGKILL');
  await until('fixture child exits', () => child.exitCode !== null || child.signalCode !== null);
}

async function connect(url) {
  socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let nextId = 0;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  });
  return (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 10000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

try {
  const plan = (name, percent = 0) => `# ${name}\n\n## Implementation Phases / Checklist\n- [ ] Work.\n\n## Current Status\n- Plan position: Ready.\n- Estimated completion: ${percent}%\n- Next work: ${percent === 100 ? 'Review.' : 'Implement.'}\n`;
  for (const directory of [repo, secondRepo]) {
    mkdirSync(directory, { recursive: true });
    execFileSync('git', ['init', '-q', directory], { env: environment });
  }
  for (const [name, percent] of [['checks', 0], ['a-long-task-name-for-responsive-dashboard-scanning', 50], ['reviewed', 100], ['blocked', 0], ['running', 50]]) {
    const directory = join(repo, '.agent', name);
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, 'plan.md'), plan(name, percent) + (name === 'blocked' ? '\n- USER ANSWER (UNRESOLVED):\n' : ''));
    if (name === 'reviewed') writeFileSync(join(directory, 'review.md'), '## Review Metadata\n- Task: reviewed\n- Grade: B+\n- Scope Reviewed: fixture delta\n- Quality Threshold: B+\n- Threshold Result: met\n\n## Blocking Production-Readiness Issues\n- None.\n');
    if (name === 'running') { mkdirSync(join(directory, 'runs')); writeFileSync(join(directory, 'runs', 'fixture.gitconfig'), '[paw]\nstatus = running\n'); }
  }
  mkdirSync(join(root, 'tasks'));
  if (baseline) writeFileSync(join(root, 'gui_server.py'), execFileSync('git', ['show', 'HEAD:scripts/lib/gui_server.py'], {cwd:checkout}));
  const server = launch('python3', ['-B', '-u', '-c',
    `import sys
from pathlib import Path
sys.path.insert(0, ${JSON.stringify(baseline ? root : join(checkout, 'scripts/lib'))})
import gui_server as gui
gui.add_repo_to_registry(gui.registry_path(), Path(${JSON.stringify(repo)}), Path(${JSON.stringify(secondRepo)}))
gui.write_queued_plan(Path(${JSON.stringify(join(root, 'tasks'))}), Path(${JSON.stringify(repo)}), 'queued-example', 'A complete queued prompt\\nwith a second line')
for repo in [Path(${JSON.stringify(repo)}), Path(${JSON.stringify(secondRepo)})]:
    task = Path(${JSON.stringify(join(root, 'tasks'))}) / gui.repo_slug(repo) / 'central-ready'
    task.mkdir(parents=True)
    (task / 'plan.md').write_text(${JSON.stringify(plan('central-ready'))})
    (task / 'metadata.gitconfig').write_text('[paw]\\nrepo-root = ' + str(repo) + '\\n')
    shared = task.with_name('shared-task')
    shared.mkdir()
    (shared / 'plan.md').write_text(${JSON.stringify(plan('shared-task'))})
    (shared / 'metadata.gitconfig').write_text((task / 'metadata.gitconfig').read_text())
def launch(repo, task_home, task_path, args):
    return True, 'Launch accepted: ' + str(repo) + ' ' + ' '.join(args)
gui.launch_paw = launch
gui.main()`, '--repo', repo, '--task-home', join(root, 'tasks'), '--port', '0']);
  await until('fixture HTTP URL', () => /http:\/\/\S+/.test(server.output));
  const url = server.output.match(/http:\/\/\S+/)[0];
  launch(chromePath, ['--headless=new', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank']);
  await until('fixture DevTools port', () => existsSync(join(profile, 'DevToolsActivePort')));
  const port = readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0];
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const call = await connect(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression: `eval(${JSON.stringify(expression)})`, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const navigateTo = async target => {
    const origin = await evaluate('performance.timeOrigin');
    await call('Page.navigate', {url:target});
    await until('new document loaded', () => evaluate(`performance.timeOrigin !== ${origin} && document.readyState === 'complete'`));
  };
  const navigate = async suffix => {
    await navigateTo(url.replace(/\/$/, '') + suffix);
    await until('dashboard loaded', () => evaluate("!!document.querySelector('#task-list')"));
  };
  const key = async (key, code, windowsVirtualKeyCode, modifiers = 0) => {
    for (const type of ['keyDown', 'keyUp']) await call('Input.dispatchKeyEvent', { type, key, code, windowsVirtualKeyCode, modifiers, ...(key === 'Enter' && type === 'keyDown' ? {text:'\r',unmodifiedText:'\r'} : {}) });
  };
  const capture = async name => {
    if (!evidence) return;
    const { data } = await call('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(evidence, name + '.png'), Buffer.from(data, 'base64'));
  };
  await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await navigate('/');
  console.log(`Browser: ${version}; isolated fixture: ${root}`);
  console.log('Table start:', await evaluate("document.querySelector('#task-list th').getBoundingClientRect().top"));
  await capture(baseline ? 'before-desktop' : 'after-desktop');
  if (baseline) {
    await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false });
    await capture('before-mobile');
  } else {
    assert.equal(await evaluate("document.querySelector('#task-list th').getBoundingClientRect().top <= 240"), true);
    assert.equal(await evaluate("!!document.querySelector('[data-new-plan]')"), true);
    await evaluate("document.querySelector('[data-new-plan] summary').click()");
    await until('Plan modal is accessible', () => evaluate("document.querySelector('[data-new-plan] [role=dialog]')?.contains(document.activeElement)"));
    assert.equal(await evaluate("document.querySelector('header').inert"), true);
    await evaluate("document.querySelector('[data-new-plan] textarea').value = 'Unsent draft'");
    await key('Escape', 'Escape', 27);
    assert.equal(await evaluate("document.querySelector('[data-new-plan]').open"), false);
    assert.equal(await evaluate("document.activeElement === document.querySelector('[data-new-plan] summary')"), true);
    await evaluate("document.querySelector('[data-new-plan] summary').click()");
    await until('reopened modal focus', () => evaluate("document.querySelector('[data-new-plan] [role=dialog]')?.contains(document.activeElement)"));
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').value"), 'Unsent draft');
    await evaluate("document.querySelector('[data-new-plan] .modal-body').click()");
    assert.equal(await evaluate("document.querySelector('[data-new-plan]').open"), true);
    await evaluate("document.querySelector('[data-new-plan] .modal-panel').click()");
    assert.equal(await evaluate("document.querySelector('[data-new-plan]').open"), false);
    assert.equal(await evaluate("document.querySelector('header').inert"), false);
    console.log('PASS: Plan dialog focus, inertness, Escape, backdrop and unsent draft');
    const openPlan = async () => {
      await evaluate("document.querySelector('[data-new-plan] summary').click()");
      await until('Plan focused', () => evaluate("document.querySelector('[data-new-plan] .modal-body').contains(document.activeElement)"));
    };
    const close = async () => { await key('Escape', 'Escape', 27); };
    await evaluate("document.querySelector('[data-open-queue]').click()");
    await until('queue dialog', () => evaluate("document.querySelector('[data-new-plan]').open"));
    assert.match(await evaluate("document.querySelector('[data-new-plan]').textContent"), /queued-example/);
    await capture('after-queued');
    await close();
    await openPlan();
    await evaluate("document.querySelector('[data-new-plan] textarea').focus()");
    writeFileSync(join(task, 'plan.md'), plan('Updated by polling'));
    await sleep(5500);
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').value"), 'Unsent draft');
    assert.equal(await evaluate("document.activeElement === document.querySelector('[data-new-plan] textarea')"), true);
    // Focus remains in the dialog in both directions at its keyboard boundaries.
    await evaluate("[...document.querySelectorAll('[data-new-plan] button')].at(-1).focus()");
    await key('Tab', 'Tab', 9);
    assert.equal(await evaluate("document.activeElement === document.querySelector('[data-new-plan] input:not([type=hidden])')"), true);
    await key('Tab', 'Tab', 9, 8);
    assert.equal(await evaluate("document.activeElement === [...document.querySelectorAll('[data-new-plan] button')].at(-1)"), true);
    await close();
    console.log('PASS: queue discovery, polling draft/focus retention and keyboard containment');

    // Deliberately ignore abort to exercise late success/error independently of transport cancellation.
    await evaluate(`window.originalFetch = window.fetch; window.previewReplies = [];
      window.fetch = (url, options) => String(url).includes('/fragments/task-doc/') ?
        new Promise((resolve, reject) => window.previewReplies.push({resolve, reject})) : window.originalFetch(url, options);`);
    const previewSelector = "[data-doc-preview-url]:not([data-doc-preview-url*=approve])";
    await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).focus(); document.querySelector(${JSON.stringify(previewSelector)}).click()`);
    assert.match(await evaluate("document.querySelector('[data-doc-preview]').textContent"), /Loading/);
    await close();
    await evaluate("window.previewReplies.shift().resolve(new Response('<div class=modal-panel><div class=modal-body><h2>Stale</h2></div></div>'))");
    await sleep(100);
    assert.equal(await evaluate("document.querySelector('[data-doc-preview]').textContent"), '');
    await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).click(); document.querySelectorAll(${JSON.stringify(previewSelector)})[1].click()`);
    await evaluate("window.previewReplies[1].resolve(new Response('<div class=modal-panel><div class=modal-body><h2>Newest</h2><button data-modal-close>Close</button><div style=height:1200px>Content</div></div></div>'))");
    await until('new preview', () => evaluate("document.querySelector('[data-doc-preview] h2')?.textContent === 'Newest'"));
    await evaluate("window.previewReplies[0].reject(new Error('Stale failure')); window.previewReplies = []; document.querySelector('[data-doc-preview] .modal-body').scrollTop = 200");
    await sleep(5500);
    assert.equal(await evaluate("document.querySelector('[data-doc-preview] h2').textContent"), 'Newest');
    assert.equal(await evaluate("document.querySelector('[data-doc-preview] .modal-body').scrollTop"), 200);
    await evaluate("document.querySelector('[data-doc-preview] .modal-body').click()");
    assert.equal(await evaluate("!!document.querySelector('[data-doc-preview] .modal-body')"), true);
    await evaluate("document.querySelector('[data-doc-preview] .modal-panel').click()");
    assert.equal(await evaluate("document.querySelector('[data-doc-preview]').textContent"), '');
    await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).click()`);
    await evaluate("window.previewReplies.shift().reject(new Error('Fixture preview unavailable'))");
    await until('preview error feedback', () => evaluate("document.querySelector('[data-doc-preview]').textContent.includes('Fixture preview unavailable')"));
    await evaluate("document.querySelector('[data-doc-preview] [data-modal-close]').click(); window.fetch = window.originalFetch");
    await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).focus(); document.querySelector(${JSON.stringify(previewSelector)}).click()`);
    await until('real preview', () => evaluate("!!document.querySelector('[data-doc-preview] .document')"));
    await capture('after-preview');
    await close();
    assert.equal(await evaluate(`document.activeElement.matches(${JSON.stringify(previewSelector)})`), true);
    console.log('PASS: loading/Close/backdrop, stale success/error, rapid replacement and unchanged preview polling');

    // A pending POST owns its frozen input until its eventual result, even after dismissal.
    await evaluate(`window.postReplies = []; window.postCount = 0;
      window.fetch = (url, options) => options?.method === 'POST' ?
        new Promise(resolve => { window.postCount++; window.postReplies.push(resolve); }) : window.originalFetch(url, options);`);
    await openPlan();
    await evaluate("const f = document.querySelector('[data-new-plan] form'); f.elements.task_name.value = 'pending'; f.elements.prompt.value = 'Submitted draft'; f.querySelector('button').click(); f.dispatchEvent(new Event('submit', {bubbles:true,cancelable:true}))");
    assert.equal(await evaluate('window.postCount'), 1);
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').disabled"), true);
    assert.equal(await evaluate("document.querySelector('[data-new-plan] [data-modal-close]').disabled"), false);
    await evaluate("document.querySelector('[data-new-plan] [data-modal-close]').click()");
    await openPlan();
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').disabled"), true);
    await close();
    await evaluate("window.postReplies.shift()(Response.json({ok:false,message:'Fixture rejection'}))");
    await until('persistent rejection', () => evaluate("document.querySelector('[data-action-feedback]').textContent === 'Fixture rejection'"));
    await openPlan();
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').value"), 'Submitted draft');
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').disabled"), false);
    await evaluate("document.querySelector('[data-new-plan] form button').click()");
    await close();
    await evaluate("window.postReplies.shift()(Response.json({ok:true,message:'Launch accepted (fixture)'}))");
    await until('persistent acceptance', () => evaluate("document.querySelector('[data-action-feedback]').textContent === 'Launch accepted (fixture)'"));
    assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').value"), '');
    await evaluate('window.fetch = window.originalFetch');
    console.log('PASS: duplicate submit guard, pending draft freeze and persistent dismissed-action results');

    // A submitted approval belongs to its own preview, even if another preview opens before its result.
    await evaluate(`window.postReplies = []; window.fetch = (url, options) => options?.method === 'POST' ?
      new Promise(resolve => window.postReplies.push(resolve)) : window.originalFetch(url, options);
      document.querySelector('[data-doc-preview-url*=approve]').click()`);
    await until('approval preview', () => evaluate("!!document.querySelector('[data-doc-preview] form[action$=implement]')"));
    await evaluate("document.querySelector('[data-doc-preview] form[action$=implement] button').click()");
    await close();
    await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).click()`);
    await until('replacement after pending approval', () => evaluate("!!document.querySelector('[data-doc-preview] .document')"));
    await evaluate("window.postReplies.shift()(Response.json({ok:true,message:'Implementation launch accepted'}))");
    await until('old approval result', () => evaluate("document.querySelector('[data-action-feedback]').textContent === 'Implementation launch accepted'"));
    assert.equal(await evaluate("!!document.querySelector('[data-doc-preview] .document')"), true);
    await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).remove()`);
    await close();
    assert.equal(await evaluate("document.activeElement.matches('.home-link, [data-new-plan] summary')"), true);
    await evaluate('window.fetch = window.originalFetch');
    console.log('PASS: pending approval cannot dismiss a replacement preview; missing opener has stable focus fallback');

    // Exercise each input overlay with the shared dismissal lifecycle.
    for (const action of ['edit', 'prototype', 'delete']) {
      await evaluate(`document.querySelector('#task-list form[action$="/${action}"]').closest('details').querySelector('summary').click()`);
      await until(action + ' focused', () => evaluate(`document.querySelector('#task-list form[action$="/${action}"]').closest('.modal-body').contains(document.activeElement)`));
      if (action !== 'delete') await evaluate(`document.querySelector('form[action$="/${action}"] textarea').value = 'Retain ${action}'`);
      await close();
      if (action !== 'delete') assert.equal(await evaluate(`document.querySelector('form[action$="/${action}"] textarea').value`), 'Retain ' + action);
    }
    assert.equal(await evaluate("document.querySelector('#selected-action-form').hidden"), true);
    await evaluate("document.querySelector('[name=task][value$=central-ready]').click()");
    assert.match(await evaluate("document.querySelector('[data-selection-count]').textContent"), /1 selected/);
    await evaluate("document.querySelector('[data-selected-action=delete]').click()");
    assert.equal(await evaluate("document.querySelector('#selected-action-form .checkbox-label').hidden"), false);
    await sleep(5500);
    assert.equal(await evaluate("document.querySelectorAll('[name=task]:checked').length"), 1);
    // Archive is a real isolated local operation; checkbox identity and clearing are observable.
    await evaluate("document.querySelector('[data-selected-action=archive]').click()");
    await until('archive selection cleared', () => evaluate("document.querySelectorAll('[name=task]:checked').length === 0 && !document.querySelector('[data-action-feedback]').textContent.includes('Submitting')"));
    assert.equal(await evaluate("document.querySelector('#selected-action-form').hidden"), true);
    console.log('PASS: input overlay drafts and contextual bulk selection through polling and success');

    await navigate('/?state=ready&completion=50%25');
    await capture('after-filtered');
    const options = await evaluate("[...document.querySelector('[data-repo-switch] select').options].map(o => o.textContent)");
    assert.equal(new Set(options).size, 2, 'duplicate repo basenames are disambiguated');
    await evaluate(`const select = document.querySelector('[data-repo-switch] select'); select.value = ${JSON.stringify(secondRepo)}; select.dispatchEvent(new Event('change', {bubbles:true}))`);
    await until('repo GET navigation', () => evaluate(`new URL(location.href).searchParams.get('active_repo') === ${JSON.stringify(secondRepo)} && document.readyState === 'complete' && document.querySelector('[data-new-plan] input[name=active_repo]').value === ${JSON.stringify(secondRepo)}`));
    assert.equal(await evaluate("new URL(location.href).searchParams.get('state')"), 'ready');
    assert.equal(await evaluate("new URL(location.href).searchParams.get('completion')"), '50%');
    assert.equal(await evaluate("document.querySelectorAll('[name=task]:checked').length"), 0);
    await openPlan();
    assert.match(await evaluate("document.querySelector('.plan-destination').textContent"), /two\/repo/);
    await evaluate("const f = document.querySelector('[data-new-plan] form'); f.elements.task_name.value = 'destination'; f.elements.prompt.value = 'Correct repo'; f.querySelector('button').click()");
    await until('correct launch repo', () => evaluate(`document.querySelector('[data-action-feedback]').textContent.includes(${JSON.stringify(secondRepo)})`));
    await capture('after-empty');
    console.log('PASS: one-step duplicate-name repo switching preserves filters and targets New Plan POST');

    await navigate('/');
    for (const [width, height, label] of [[1440,900,'desktop'],[1024,768,'laptop'],[390,844,'mobile'],[720,450,'zoom-200']]) {
      await call('Emulation.setDeviceMetricsOverride', {width,height,deviceScaleFactor:label === 'zoom-200' ? 2 : 1,mobile:false});
      assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, label + ' page overflow');
      await capture('after-' + label);
      await openPlan();
      assert.equal(await evaluate("const b = document.querySelector('[data-new-plan] .modal-body').getBoundingClientRect(); b.left >= 0 && b.right <= innerWidth && b.top >= 0 && b.bottom <= innerHeight"), true, label + ' dialog fits');
      await evaluate("document.querySelector('[data-new-plan] .modal-body').scrollTop = 10000");
      assert.equal(await evaluate("const b = [...document.querySelectorAll('[data-new-plan] button')].at(-1).getBoundingClientRect(); b.top >= 0 && b.bottom <= innerHeight"), true, label + ' final action reachable');
      await evaluate("const wrap = document.querySelector('[data-new-plan] .table-wrap'); if (wrap) wrap.scrollLeft = wrap.scrollWidth");
      assert.equal(await evaluate("const b = [...document.querySelectorAll('[data-new-plan] button')].at(-1).getBoundingClientRect(); b.right <= innerWidth"), true, label + ' queued actions horizontally reachable');
      await capture('after-dialog-' + label);
      await close();
    }
    await call('Emulation.setDeviceMetricsOverride', {width:1440,height:900,deviceScaleFactor:1,mobile:false});
    await navigateTo(url + 'archive');
    await until('archive page', () => evaluate("document.querySelector('h1')?.textContent === 'Archived Tasks'"));
    await capture('after-archived');
    assert.equal(await evaluate("!!document.querySelector('form[action$=unarchive]')"), true);
    // Detail shares the dialog lifecycle and persistent feedback, with metadata collapsed.
    await navigateTo(url + 'task/reviewed?path=' + encodeURIComponent(join(repo,'.agent/reviewed')));
    await until('detail navigation', () => evaluate("!!document.querySelector('#task-detail')"));
    assert.equal(await evaluate("document.querySelector('.task-metadata').open"), false);
    assert.equal(await evaluate("document.querySelectorAll('form[action$=archive]').length"), 1);
    await capture('after-detail');
    await evaluate("document.querySelector('form[action$=review]').closest('details').querySelector('summary').click()");
    await until('Review dialog', () => evaluate("document.querySelector('form[action$=review]').closest('.modal-body').contains(document.activeElement)"));
    await evaluate("document.querySelector('form[action$=review] textarea').value = 'Review draft'");
    await close();
    await evaluate("document.querySelector('form[action$=review]').closest('details').querySelector('summary').click()");
    await until('Review reopened', () => evaluate("document.querySelector('form[action$=review]').closest('.modal-body').contains(document.activeElement)"));
    assert.equal(await evaluate("document.querySelector('form[action$=review] textarea').value"), 'Review draft');
    await evaluate("document.querySelector('form[action$=review] button').click()");
    await until('detail acceptance', () => evaluate("document.querySelector('[data-action-feedback]').textContent.includes('Launch accepted')"));
    assert.equal(await evaluate("!!document.querySelector('#task-detail')"), true);
    console.log('PASS: detail metadata, single Archive, Review draft and inline acceptance');

    const allServer = launch('python3', ['-B','-u','-c', `import sys
sys.path.insert(0, ${JSON.stringify(join(checkout,'scripts/lib'))})
import gui_server as gui
gui.launch_paw = lambda repo, home, task, args: (True, 'Launch accepted: ' + str(repo) + ' ' + ' '.join(args))
gui.main()`, '--repo', repo, '--task-home', join(root,'tasks'), '--port','0','--all']);
    await until('all-repo server', () => /http:\/\/\S+/.test(allServer.output));
    const allUrl = allServer.output.match(/http:\/\/\S+/)[0];
    await navigateTo(allUrl);
    await until('all-repo dashboard', () => evaluate("document.querySelector('.header-context')?.textContent === 'All task stores'"));
    const identities = await evaluate("[...document.querySelectorAll('#task-list tr[data-paw-key]')].map(r=>r.dataset.pawKey).sort()");
    assert.equal(identities.filter(path => path.endsWith('/shared-task')).length, 2);
    await evaluate(`const select = document.querySelector('[data-repo-switch] select'); select.value = ${JSON.stringify(secondRepo)}; select.dispatchEvent(new Event('change',{bubbles:true}))`);
    await until('all-repo selected destination', () => evaluate(`document.readyState === 'complete' && document.querySelector('[data-new-plan] input[name=active_repo]')?.value === ${JSON.stringify(secondRepo)}`));
    assert.deepEqual(await evaluate("[...document.querySelectorAll('#task-list tr[data-paw-key]')].map(r=>r.dataset.pawKey).sort()"), identities);
    await openPlan();
    await evaluate("const f = document.querySelector('[data-new-plan] form'); f.elements.task_name.value = 'all-target'; f.elements.prompt.value = 'All repo target'; f.querySelector('button').click()");
    await until('all-repo accepted target', () => evaluate(`document.querySelector('[data-action-feedback]').textContent.includes(${JSON.stringify(secondRepo)})`));
    await capture('after-all-repos');
    await evaluate("document.querySelector('[name=task][value$=shared-task]').click(); document.querySelector('[data-selected-action=delete]').click(); document.querySelector('[data-confirm-delete]').click()");
    await until('delete rejection', () => evaluate("document.querySelector('[data-action-feedback]').textContent.includes('delete confirmation is required')"));
    assert.equal(await evaluate("document.querySelectorAll('[name=task]:checked').length"), 1);
    await evaluate("document.querySelector('#selected-action-form input[name=confirm]').click(); document.querySelector('[data-confirm-delete]').click()");
    await until('exact all-repo deletion', () => evaluate("document.querySelectorAll('[name=task]:checked').length === 0 && document.querySelectorAll('[name=task][value$=shared-task]').length === 1"));
    console.log('PASS: all-repo listing preserved across switching, exact Plan destination and guarded bulk task identity');

    // No-JavaScript fallback uses ordinary GET and POST forms.
    await call('Emulation.setScriptExecutionDisabled', {value:true});
    await navigateTo(url);
    await until('fallback page', () => evaluate("document.readyState === 'complete' && !!document.querySelector('[data-repo-switch]')"));
    assert.equal(await evaluate("getComputedStyle(document.querySelector('.switch-fallback')).display !== 'none'"), true);
    assert.equal(await evaluate("getComputedStyle(document.querySelector('.selection-fallback')).display !== 'none'"), true);
    await evaluate(`document.querySelector('[data-repo-switch] select').value = ${JSON.stringify(secondRepo)}; document.querySelector('.switch-fallback').focus()`);
    await key('Enter','Enter',13);
    await until('fallback switched', () => evaluate(`document.readyState === 'complete' && document.querySelector('[data-new-plan] input[name=active_repo]')?.value === ${JSON.stringify(secondRepo)}`));
    await evaluate("document.querySelector('[data-new-plan] summary').focus()");
    await key('Enter','Enter',13);
    await evaluate("const f = document.querySelector('[data-new-plan] form'); f.elements.task_name.value = 'fallback-target'; f.elements.prompt.value = 'Native POST'; f.querySelector('button').focus()");
    await key('Enter','Enter',13);
    await until('native POST accepted', () => evaluate(`document.readyState === 'complete' && document.querySelector('.flash')?.textContent.includes(${JSON.stringify(secondRepo)})`));
    await call('Emulation.setScriptExecutionDisabled', {value:false});
    console.log('PASS: desktop/laptop/mobile/200% equivalent layout, reachable dialogs, archived recovery and fallback forms');


  }
} catch (error) {
  for (const child of children) if (child.errors) console.error(child.errors.slice(-2000));
  throw error;
} finally {
  socket?.close();
  for (const child of children.reverse()) await stop(child);
  rmSync(root, { recursive: true, force: true });
  console.log('Cleanup: fixture processes reaped and temporary profile/store removed');
}
