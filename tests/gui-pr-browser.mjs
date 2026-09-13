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
const root = realpathSync(mkdtempSync(join(tmpdir(), 'paw-pr-browser-')));
const repo = join(root, 'repo');
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
  mkdirSync(task, {recursive:true});
  execFileSync('git', ['init', '-q', repo], {env:environment});
  execFileSync('git', ['-C', repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '--allow-empty', '-qm', 'fixture'], {env:environment});
  const server = launch('python3', ['-B', '-u', '-c', `
import sys, json, time
from pathlib import Path
sys.path.insert(0, ${JSON.stringify(join(checkout, 'scripts/lib'))})
import gui_server as gui
import pr_publication as pr
import review_record as review
repo, root = Path(${JSON.stringify(repo)}), Path(${JSON.stringify(root)})
body = repo / '.agent/branch-pr.md'
body.write_text('Unimplemented plan stays local.\\n\\n## Visual Evidence\\n\\nThis shows the reviewed publication transition.\\n\x60\x60\x60mermaid\\nflowchart TD\\n A --> B\\n\x60\x60\x60\\n')
for name, grade in [('checks', 'A-'), ('second', 'A'), ('lower', 'B+')]:
    task = repo / '.agent' / name
    task.mkdir(exist_ok=True)
    (task / 'plan.md').write_text('## Current Status\\n- Estimated completion: 100%\\n- Next work: Review.\\n\\n## PR Contribution\\n- Outcome: Reviewed publication works.\\n- Validation: Isolated behavior tests passed.\\n- Risks: External editing races remain.\\n- Visual: Shared diagram covers publication.\\n')
    (task / 'review.md').write_text(f'## Review Metadata\\n- Task: {name}\\n- Grade: {grade}\\n- Scope Reviewed: fixture\\n- Quality Threshold: B+\\n- Threshold Result: met\\n- Completion: complete\\n- Attempt: fixture\\n- Reviewed Code: {review.code_identity(repo)}\\n## Blocking Production-Readiness Issues\\n- None.\\n')
    (task / '.review-attempt').write_text('fixture\\tcomplete\\n')
original = pr.command
remote = None
pr.assignment = lambda *a: (repo, 'feature')
pr.body_file = lambda *a: body
pr.remote_identity = lambda *a: dict(repository='fixture/repo', head_repository='fixture/repo', head='fixture:feature', branch='feature', sha=original(repo, 'git', 'rev-parse', 'HEAD'))
pr.lookup = lambda *a: dict(remote) if remote else None
def command(directory, *args):
    global remote
    if args[0] != 'gh':
        return original(directory, *args)
    candidate = Path(args[args.index('--body-file')+1]).read_text()
    remote = dict(number=123, url='https://github.com/fixture/repo/pull/123', body=candidate)
    (root / 'remote.json').write_text(json.dumps(remote))
    return remote['url']
pr.command = command
prepare = pr.prepare
def delayed(*a, **kw):
    if (root / 'delay').exists(): time.sleep(2)
    if (root / 'fail').exists(): raise ValueError('gh authentication failed (fixture)')
    return prepare(*a, **kw)
pr.prepare = delayed
gui.main()
`, '--repo', repo, '--task-home', join(root, 'tasks'), '--port', '0']);
  await until('fixture HTTP URL', () => /http:\/\/\S+/.test(server.output));
  const url = server.output.match(/http:\/\/\S+/)[0];
  launch(chromePath, ['--headless=new', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank']);
  await until('DevTools', () => existsSync(join(profile, 'DevToolsActivePort')));
  const port = readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0];
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const call = await connect(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', {expression, returnByValue:true, awaitPromise:true});
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const screenshot = async name => {
    if (!process.env.PAW_GUI_EVIDENCE) return;
    mkdirSync(process.env.PAW_GUI_EVIDENCE, {recursive:true});
    const shot = await call('Page.captureScreenshot', {format:'png'});
    writeFileSync(join(process.env.PAW_GUI_EVIDENCE, name + '.png'), Buffer.from(shot.data, 'base64'));
  };
  await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', {width:1440,height:900,deviceScaleFactor:1,mobile:false});
  await call('Emulation.setEmulatedMedia', {features:[{name:'prefers-color-scheme',value:'light'}]});
  await call('Page.navigate', {url});
  await until('eligible Next', () => evaluate("!!document.querySelector('form[action=\"/task/checks/pr-preview\"]')"));
  assert.equal(await evaluate("!!document.querySelector('form[action=\"/task/lower/pr-preview\"]')"), false);
  assert.equal(existsSync(join(root, 'remote.json')), false);
  const bounds = await evaluate(`(() => {
    const button = document.querySelector('form[action="/task/checks/pr-preview"] button');
    button.scrollIntoView({block:'center'});
    const r = button.getBoundingClientRect();
    return {visible:r.width > 0 && r.height > 0 && r.top >= 0 && r.left >= 0 && r.bottom <= innerHeight && r.right <= innerWidth,
      light:matchMedia('(prefers-color-scheme: light)').matches, label:button.textContent};
  })()`);
  assert.equal(bounds.visible, true);
  assert.equal(bounds.light, true);
  assert.match(bounds.label, /Update PR/);
  await screenshot('pr-next-light');
  await evaluate("document.querySelector('form[action=\"/task/checks/pr-preview\"] button').click()");
  await until('candidate', () => evaluate("!!document.querySelector('[data-doc-preview] form[action$=pr-update]')"));
  assert.equal(await evaluate("document.querySelector('[data-doc-preview]').textContent.includes('Unimplemented plan stays local')"), false);
  await screenshot('pr-preview-light');
  await call('Emulation.setDeviceMetricsOverride', {width:390,height:844,deviceScaleFactor:1,mobile:true});
  await call('Emulation.setEmulatedMedia', {features:[{name:'prefers-color-scheme',value:'dark'}]});
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true);
  await screenshot('pr-preview-dark-narrow');
  await evaluate("document.querySelector('[data-doc-preview] form button').click(); document.querySelector('[data-doc-preview] form button').click()");
  await until('result', () => evaluate("document.querySelector('[data-action-feedback] a')?.href === 'https://github.com/fixture/repo/pull/123'"));
  await screenshot('pr-result-dark-narrow');
  assert.equal(JSON.parse(readFileSync(join(root, 'remote.json'))).body.match(/## Task: checks/g).length, 1);
  await call('Emulation.setDeviceMetricsOverride', {width:1440,height:900,deviceScaleFactor:1,mobile:false});
  await evaluate("document.querySelector('form[action=\"/task/second/pr-preview\"] button').click()");
  await until('second candidate', () => evaluate("!!document.querySelector('[data-doc-preview] form[action=\"/task/second/pr-update\"]')"));
  await evaluate("document.querySelector('[data-doc-preview] form button').click()");
  await until('second remote contribution', () => existsSync(join(root, 'remote.json')) && JSON.parse(readFileSync(join(root, 'remote.json'))).body.includes('## Task: second'));
  assert.equal(JSON.parse(readFileSync(join(root, 'remote.json'))).body.match(/## Task: checks/g).length, 1);
  await until('submission idle', () => evaluate("!document.querySelector('[data-doc-preview] form')"));
  writeFileSync(join(root, 'delay'), 'delay');
  await evaluate("document.querySelector('form[action=\"/task/checks/pr-preview\"] button').click(); document.querySelector('[data-new-plan]').open = true");
  await until('new plan dialog', () => evaluate("!!document.querySelector('[data-new-plan][open] textarea')"));
  const draft = 'Exact unsent text\nwith unicode λ and spaces  ';
  await evaluate(`(() => { const t=document.querySelector('[data-new-plan] textarea'); t.value=${JSON.stringify(draft)}; t.focus(); t.setSelectionRange(3,9); })()`);
  await sleep(6000);
  assert.equal(await evaluate("document.querySelector('[data-new-plan]').open"), true);
  assert.equal(await evaluate("document.querySelector('[data-new-plan] textarea').value"), draft);
  assert.deepEqual(await evaluate("[document.activeElement.selectionStart, document.activeElement.selectionEnd]"), [3,9]);
  assert.equal(await evaluate("!!document.querySelector('[data-doc-preview] form')"), false);
  await evaluate("document.querySelector('[data-new-plan] [data-modal-close]').click()");
  rmSync(join(root, 'delay'));
  writeFileSync(join(root, 'fail'), 'failure');
  await evaluate("document.querySelector('form[action=\"/task/checks/pr-preview\"] button').click()");
  await until('failure guidance', () => evaluate("document.querySelector('[data-action-feedback]').textContent.includes('authentication failed')"));
  rmSync(join(root, 'fail'));
  await call('Emulation.setScriptExecutionDisabled', {value:true});
  const nativeOrigin = await evaluate('performance.timeOrigin');
  await call('Page.navigate', {url});
  await until('native navigation', () => evaluate(`performance.timeOrigin !== ${nativeOrigin} && document.readyState === 'complete'`));
  await until('native page', () => evaluate("!!document.querySelector('form[action=\"/task/checks/pr-preview\"]')"));
  const position = await evaluate("(() => { const b=document.querySelector('form[action=\"/task/checks/pr-preview\"] button'); b.scrollIntoView(); const r=b.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2,disabled:b.disabled}; })()");
  assert.equal(position.disabled, false);
  await call('Input.dispatchMouseEvent', {type:'mousePressed',x:position.x,y:position.y,button:'left',clickCount:1});
  await call('Input.dispatchMouseEvent', {type:'mouseReleased',x:position.x,y:position.y,button:'left',clickCount:1});
  try { await until('native candidate', () => evaluate("!!document.querySelector('.publication-panel form')")); } catch (error) { console.error(await evaluate('location.href + document.body.innerText')); console.error(server.errors); throw error; }
  assert.equal(await evaluate("!!document.querySelector('form[action=\"/task/checks/archive\"]')"), true);
  console.log('PASS: PR Next, lower-grade refusal, shared two-task visual/body, duplicate clicks, result link, delayed preview/draft/focus/caret/polling, failure guidance, native fallback and light/dark narrow screenshots');
} finally {
  socket?.close();
  for (const child of children.reverse()) await stop(child);
  rmSync(root, {recursive:true, force:true});
}
