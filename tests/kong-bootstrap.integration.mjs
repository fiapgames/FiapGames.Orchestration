import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, unlinkSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const context = process.env.KUBE_CONTEXT ?? 'docker-desktop';
if (!/^(docker-desktop|kind-[a-z0-9-]+)$/.test(context))
  throw new Error('This test only runs on Docker Desktop or Kind, never on an AWS context.');
const namespace = `fiap-kong-reload-${randomBytes(4).toString('hex')}`;
const temporary = mkdtempSync(join(tmpdir(), 'fiap-kong-reload-'));
const files = [];
let created = false;
let passed = 0;
const kubectlArgs = ['--context', context, '-n', namespace];
function kubectl(args, input) {
  return execFileSync('kubectl', [...kubectlArgs, ...args], {
    cwd: root, encoding: 'utf8', input, timeout: 660000, stdio: ['pipe', 'pipe', 'pipe'],
  }).trim();
}
function fixture(name, content) {
  const path = join(temporary, name);
  writeFileSync(path, content, { mode: 0o600 }); files.push(path); return path;
}
function manifest(name) {
  return readFileSync(join(root, name), 'utf8').replaceAll('fiapgames', namespace);
}
const current = manifest('kong/kong.k8s.yml');
const previous = current.replace(/      - name: catalog-search\r?\n        paths: \["\/search"\]\r?\n        strip_path: false\r?\n/, '');
assert.notEqual(previous, current, 'The old fixture must omit the search route.');
const oldConfig = fixture('old-kong.yml', previous);
const newConfig = fixture('new-kong.yml', current);
const job = fixture('01-job.yaml', manifest('k8s/kong/01-kong-bootstrap-job.yaml'));
const deployment = fixture('02-deployment.yaml', manifest('k8s/kong/02-kong.yaml').split(/^---\s*$/m)[0]);
const dbConfig = fixture('00-db.yaml', manifest('k8s/kong/00-kong-db-config.yaml'));
// Only these manifests are passed to the production helper; omit optional Konga
// and fixed NodePort Services to avoid interfering with other local workloads.
const manifests = fixture('gateway.yaml', [readFileSync(dbConfig,'utf8'), readFileSync(job,'utf8'), readFileSync(deployment,'utf8')].join('\n---\n'));
const bash = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : 'bash';
function bootstrap(config) {
  execFileSync(bash, ['ci/bootstrap-kong.sh', manifests.replaceAll('\\', '/'), config.replaceAll('\\', '/')], {
    cwd: root, encoding: 'utf8', timeout: 660000, stdio: 'inherit',
    env: { ...process.env, KUBE_CONTEXT: context, NAMESPACE: namespace },
  });
}
function pass(description) { passed++; console.log(`PASS ${description}`); }
function jobUid() { return kubectl(['get', 'job', 'kong-bootstrap', '-o', 'jsonpath={.metadata.uid}']); }
function routeCount(name) {
  assert.match(name, /^[a-z-]+$/);
  return Number(kubectl(['exec', 'postgres-kong', '--', 'sh', '-c',
    `PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U kong -d kong -tA -c "SELECT COUNT(*) FROM routes WHERE name='${name}';"`]));
}
async function proxyStatus() {
  const processHandle = spawn('kubectl', [...kubectlArgs, 'port-forward', 'deployment/kong', '0:8000', '--address', '127.0.0.1'], { cwd: root });
  let output = '';
  try {
    const port = await new Promise((resolvePort, reject) => {
      const timer = setTimeout(() => reject(new Error('Port-forward did not become ready.')), 20000);
      processHandle.stdout.on('data', chunk => {
        output += chunk;
        const match = output.match(/127\.0\.0\.1:(\d+) -> 8000/);
        if (match) { clearTimeout(timer); resolvePort(Number(match[1])); }
      });
      processHandle.on('error', error => { clearTimeout(timer); reject(error); });
      processHandle.on('exit', code => { clearTimeout(timer); reject(new Error(`Port-forward exited (${code}).`)); });
    });
    const response = await fetch(`http://127.0.0.1:${port}/search?q=minecrfat`, { signal: AbortSignal.timeout(10000) });
    return response.status;
  } finally { processHandle.kill(); }
}

try {
  execFileSync('kubectl', ['--context', context, 'create', 'namespace', namespace], { encoding: 'utf8', stdio: 'inherit' });
  created = true;
  kubectl(['apply', '-f', '-'], JSON.stringify({
    apiVersion: 'v1', kind: 'Secret', metadata: { name: 'infra-credentials', namespace }, type: 'Opaque',
    stringData: { 'kong-db-password': randomBytes(24).toString('hex'), 'jwt-secret-key': randomBytes(32).toString('hex') },
  }));
  kubectl(['apply', '-f', '-'], JSON.stringify({
    apiVersion: 'v1', kind: 'Pod', metadata: { name: 'postgres-kong', namespace, labels: { app: 'postgres-kong' } },
    spec: { containers: [{ name: 'postgres', image: 'postgres:11.16', env: [
      { name: 'POSTGRES_USER', value: 'kong' }, { name: 'POSTGRES_DB', value: 'kong' },
      { name: 'POSTGRES_PASSWORD', valueFrom: { secretKeyRef: { name: 'infra-credentials', key: 'kong-db-password' } } },
    ], readinessProbe: { exec: { command: ['pg_isready','-U','kong'] }, periodSeconds: 2 },
    volumeMounts: [{ name: 'data', mountPath: '/var/lib/postgresql/data' }] }], volumes: [{ name: 'data', emptyDir: {} }] },
  }));
  kubectl(['apply', '-f', '-'], JSON.stringify({ apiVersion:'v1', kind:'Service', metadata:{name:'postgres-kong',namespace},
    spec:{selector:{app:'postgres-kong'},ports:[{port:5432,targetPort:5432}]}}));
  kubectl(['wait', '--for=condition=Ready', 'pod/postgres-kong', '--timeout=180s']);
  const postgresUid = kubectl(['get','pod','postgres-kong','-o','jsonpath={.metadata.uid}']);

  bootstrap(oldConfig);
  const firstUid = jobUid();
  assert.equal(routeCount('catalog-search'), 0);
  assert.equal(await proxyStatus(), 404);
  pass('initial configuration has no search route');

  // Reproduce the original failure: Secret update plus apply of a completed Job.
  kubectl(['apply','-f','-'],JSON.stringify({apiVersion:'v1',kind:'Secret',metadata:{name:'kong-declarative-config',namespace},
    type:'Opaque',stringData:{'kong.yml.template':current}}));
  kubectl(['apply','-f',job]);
  assert.equal(jobUid(), firstUid);
  assert.equal(routeCount('catalog-search'), 0);
  pass('reapplying the completed Job leaves the old database configuration unchanged');

  bootstrap(newConfig);
  assert.notEqual(jobUid(), firstUid);
  assert.equal(routeCount('catalog-search'), 1);
  assert.equal(await proxyStatus(), 401);
  assert.equal(kubectl(['get','pod','postgres-kong','-o','jsonpath={.metadata.uid}']), postgresUid);
  pass('production helper recreates the import Job and activates authenticated search without replacing Postgres');

  const secondUid = jobUid();
  bootstrap(newConfig);
  assert.notEqual(jobUid(), secondUid);
  assert.equal(routeCount('catalog-search'), 1);
  assert.equal(routeCount('catalog-games'), 1);
  assert.equal(await proxyStatus(), 401);
  pass('another bootstrap is idempotent and preserves existing routes');
  console.log(`${passed} Kubernetes integration scenarios passed.`);
} catch (error) {
  // Report only the error message; child-process objects can include Secret stdin.
  console.error(error.message);
  if (created) {
    console.error(kubectl(['get','pods','-o','wide']));
    try { console.error(kubectl(['logs','job/kong-bootstrap','-c','seed','--tail=30'])); } catch {}
  }
  process.exitCode = 1;
} finally {
  try {
    if (created) kubectl(['delete','namespace',namespace,'--wait=true','--timeout=180s']);
  } finally {
    for (const path of files) unlinkSync(path);
    rmdirSync(temporary);
  }
}
