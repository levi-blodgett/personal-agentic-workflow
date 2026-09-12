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
  mkdirSync(task, { recursive: true });
  mkdirSync(join(root, 'tasks'));
  execFileSync('git', ['init', '-q', repo], { env: environment });
  const record = body => writeFileSync(join(task, 'plan.md'), '## Validation Performed\n' + body);
  record('');
  const server = launch('python3', ['-B', '-u', '-c',
    `import sys
sys.path.insert(0, ${JSON.stringify(join(checkout, 'scripts/lib'))})
import gui_server as gui
gui.launch_paw = lambda *args: (True, 'started paw review (fixture)')
gui.main()`,
    '--repo', repo, '--task-home', join(root, 'tasks'), '--port', '0']);
  await until('fixture HTTP URL', () => /http:\/\/\S+/.test(server.output));
  const url = server.output.match(/http:\/\/\S+/)[0];
  launch(chromePath, ['--headless=new', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank']);
  await until('fixture DevTools port', () => existsSync(join(profile, 'DevToolsActivePort')));
  const port = readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0];
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const call = await connect(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const key = async (key, code, windowsVirtualKeyCode) => {
    for (const type of ['keyDown', 'keyUp']) await call('Input.dispatchKeyEvent', { type, key, code, windowsVirtualKeyCode });
  };
  const state = async (value, detail = false) => until(`rendered ${value}`, () =>
    evaluate(`!!document.querySelector(${JSON.stringify((detail ? '#validation ' : '') + '.validation-' + value)})`));
  await call('Page.enable');
  await call('Page.navigate', { url });
  await state('missing');
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.validation-missing')).color"), 'rgb(102, 112, 133)');
  console.log(`Browser: ${version}; fixture: ${root}; URL: ${url}`);
  console.log('PASS: initial Unvalidated badge is gray');

  record('### Context\n- package lint: passed');
  await sleep(5500);
  await state('missing');
  record('### Context\n- package lint: passed\n### Implementation results\n- tests: passed');
  await state('passed');
  record('- tests: passed\n- browser: not executed');
  await state('recorded');
  const hostile = '<script>globalThis.pawHostileExecuted = true</script>';
  const diagnostic = 'line one\n  ' + hostile + '\n  ' + 'long-evidence-'.repeat(500);
  const failure = '- tests: failed because expected output differs\n  ' + diagnostic + '\n- lint: passed';
  record(failure);
  await state('attention');
  console.log('PASS: dashboard polling handles context, success, incomplete and failed diagnostics');

  for (let attempt = 0; attempt < 100; attempt++) {
    if (await evaluate("document.activeElement?.textContent === 'Validation details'")) break;
    await key('Tab', 'Tab', 9);
  }
  assert.equal(await evaluate('document.activeElement.textContent'), 'Validation details');
  await key('Enter', 'Enter', 13);
  await state('attention', true);
  await until('hash opens disclosure', () => evaluate("location.hash === '#validation' && document.querySelector('#validation').open"));
  assert.equal(await evaluate(`document.querySelector('.validation-evidence').textContent`), failure.split('\n- lint:')[0]);
  assert.equal(await evaluate("document.querySelector('#validation script') === null && !globalThis.pawHostileExecuted"), true);
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.validation-evidence')).whiteSpace"), 'pre-wrap');
  await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  assert.equal(await evaluate(`Array.from(document.querySelectorAll('.validation-evidence')).every(element =>
    getComputedStyle(element).overflowWrap === 'anywhere' && element.scrollWidth <= element.clientWidth + 1
    && element.getBoundingClientRect().right <= innerWidth)`), true);
  console.log('PASS: keyboard navigation, complete escaped multiline evidence and 390px wrapping');

  await evaluate("document.querySelector('#validation summary').focus()");
  await key(' ', 'Space', 32);
  assert.equal(await evaluate("document.querySelector('#validation').open"), false);
  const resolved = failure + '\n- tests: passed (rerun; supersedes earlier result)';
  record(resolved);
  await state('passed', true);
  await sleep(5500);
  assert.equal(await evaluate("document.querySelector('#validation').open"), false);
  assert.equal(await evaluate("document.querySelector('#validation').textContent.includes('expected output differs')"), true);
  await evaluate("document.querySelector('#validation summary').focus()");
  await key(' ', 'Space', 32);
  record(resolved + '\n- browser: unavailable');
  await state('attention', true);
  await sleep(5500);
  assert.equal(await evaluate("document.querySelector('#validation').open"), true);
  console.log('PASS: exact rerun retains history; open and closed disclosures survive two polls');

  for (const first of ['- tests: passed; browser: failed', '- tests: passed\n  browser: exit 1']) {
    const nested = first + '\n- tests: passed (rerun; supersedes earlier result)';
    record(nested);
    await until('new nested evidence', () => evaluate(`document.querySelector('.validation-evidence')?.textContent === ${JSON.stringify(first)}`));
    await state('attention', true);
    assert.match(await evaluate("document.querySelector('#validation > p').textContent"), /browser/);
    record(nested + '\n- browser: passed (rerun; supersedes earlier result)');
    await state('passed', true);
  }
  for (const [check, expected] of [
    ['browser: unknown', 'recorded'], ['browser: expected to run later', 'recorded'],
    ['browser: blocked', 'attention'], ['lint failed', 'attention'],
  ]) {
    record('- tests: passed\n  - ' + check);
    await until('new uncertain/adverse evidence', () => evaluate(
      `document.querySelector('.validation-evidence')?.textContent.includes(${JSON.stringify(check)})`));
    await state(expected, true);
  }
  console.log('PASS: parent reruns preserve nested/compound failures until an exact browser rerun');

  const detailUrl = await evaluate('location.href');
  for (const [name, initial] of [
    ['Run browser', '- tests: passed\n- Run browser: failed'],
    ['next check', '- tests: passed\n  1. next check: failed'],
    ['browser', '- browser: failed\n- tests: passed\n  Log:\n    ' + hostile +
      '\n    browser: passed (rerun; supersedes earlier result)'],
  ]) {
    const unrelated = initial + '\n- tests: passed (rerun; supersedes earlier result)';
    for (const [body, expected] of [
      [initial, 'attention'], [unrelated, 'attention'],
      [unrelated + '\n- ' + name + ': passed (rerun; supersedes earlier result)', 'passed'],
    ]) {
      record(body);
      await until('review regression evidence polls into detail', () => evaluate(
        `Array.from(document.querySelectorAll('.validation-evidence')).map(e => e.textContent).join('\\n') === ${JSON.stringify(body)}`));
      await state(expected, true);
      assert.equal(await evaluate("document.querySelector('#validation').open"), true);
      assert.equal(await evaluate("document.querySelector('#validation script') === null && !globalThis.pawHostileExecuted"), true);
      await call('Page.navigate', { url });
      await state(expected);
      await call('Page.navigate', { url: detailUrl });
      await state(expected, true);
      await until('review regression disclosure reopens from hash', () => evaluate("document.querySelector('#validation').open"));
    }
  }
  console.log('PASS: reviewed name/Log failures agree across dashboard and detail; only real exact reruns resolve');

  await evaluate("Array.from(document.querySelectorAll('a')).find(a => a.textContent === 'Open plan.md source').focus()");
  await key('Enter', 'Enter', 13);
  await until('source link', () => evaluate("location.hash === '#validation-source' && !!document.getElementById('validation-source')"));
  assert.equal(await evaluate("new URL(location.href).searchParams.get('path')"), task);
  assert.equal(await evaluate("new URL(location.href).searchParams.get('active_repo')"), repo);
  console.log('PASS: keyboard source link resolves to the exact fixture plan');

  execFileSync('git', ['config', '--file', join(task, 'metadata.gitconfig'), 'paw.prototype-status', 'planned']);
  writeFileSync(join(task, 'plan.md'), '## Current Status\n- Estimated completion: 100%\n- Next work: Review.\n');
  await call('Page.navigate', { url });
  await until('completed replacement offers Review', () => evaluate("!!document.querySelector('form[action$=review]')"));
  await evaluate("document.querySelector('form[action$=review] button').click()");
  await until('stubbed Review launch', () => evaluate("document.body.textContent.includes('started paw review (fixture)')"));
  writeFileSync(join(task, 'review.md'), '## Review Metadata\n- Grade: **B+**.\n');
  await until('clean B+ badge', () => evaluate("document.querySelector('.review-grade.grade-b')?.textContent === 'Review grade: B+'"));
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.grade-b')).color"), 'rgb(29, 78, 216)');
  await sleep(5500);
  assert.equal(await evaluate("document.querySelector('.review-grade').textContent"), 'Review grade: B+');
  writeFileSync(join(task, 'review.md'), '## Review Metadata\n- Grade: **A-**.\n');
  await until('formatted A- restriction', () => evaluate("document.querySelector('.grade-a')?.textContent === 'Review grade: A-' && document.body.textContent.includes('Prototype disabled for review grade A-')"));
  console.log('PASS: completed replacement launches stubbed Review; bold B+ stays clean/blue through polling; A- restricts prototype');

} catch (error) {
  for (const child of children) if (child.errors) console.error(child.errors.slice(-4000));
  throw error;
} finally {
  socket?.close();
  for (const child of children.reverse()) await stop(child);
  rmSync(root, { recursive: true, force: true });
  console.log('Cleanup: fixture processes reaped and temporary profile/store removed');
}
