#!/usr/bin/env node

/**
 * Reduce a built CloudCLI tree to the packages its compiled server can load.
 *
 * Frontend dependencies are already bundled in dist/. The server dependency
 * roots below are deliberately explicit and are checked against imports found
 * in dist-server/, so an upstream upgrade fails closed instead of silently
 * deleting a newly required package.
 */

import { spawnSync } from 'node:child_process';
import { builtinModules } from 'node:module';
import {
  existsSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';

const RUNTIME_ROOTS = Object.freeze([
  '@anthropic-ai/claude-agent-sdk',
  // Agent SDK peers are retained defensively even though the published JS is
  // bundled today; this avoids coupling the product to that implementation detail.
  '@anthropic-ai/sdk',
  '@modelcontextprotocol/sdk',
  'zod',
  '@iarna/toml',
  '@octokit/rest',
  // Keep the small JS integration so the source can regain Codex later. Its
  // native CLI payload is intentionally excluded from current iGemini builds.
  '@openai/codex-sdk',
  '@vscode/ripgrep',
  'bcrypt',
  'better-sqlite3',
  'chokidar',
  'cors',
  'cross-spawn',
  'express',
  'gray-matter',
  'jsonwebtoken',
  'mime-types',
  'multer',
  'node-pty',
  'shell-quote',
  'web-push',
  'ws',
]);

const OPTIONAL_SERVER_IMPORTS = new Set([
  // Browser-use is an upstream optional feature; CloudCLI already omits
  // Playwright from production installs and handles its absence at runtime.
  'playwright',
]);

const FORBIDDEN_PACKAGE = [
  /^@anthropic-ai\/claude-agent-sdk-(?:darwin|linux|win32)-/,
  /^@openai\/codex$/,
  /^@openai\/codex-(?:darwin|linux|win32)-/,
];

const STRIP_ROOT_ENTRIES = [
  '.git', '.github', '.husky', 'electron', 'public', 'server', 'src', 'tests', 'test',
  '.env.example', '.gitignore', '.gitmodules', '.npmignore', '.nvmrc', '.release-it.json',
  'CHANGELOG.md', 'CONTRIBUTING.md',
  'README.md', 'README.de.md', 'README.ja.md', 'README.ko.md', 'README.ru.md',
  'README.tr.md', 'README.zh-CN.md', 'README.zh-TW.md',
  'commitlint.config.js', 'docker', 'docs', 'index.html', 'plugins', 'redirect-package',
  'release.sh', 'scripts', 'shared',
  'eslint.config.js', 'postcss.config.js', 'tailwind.config.js', 'tsconfig.json',
  'tsconfig.node.json', 'vite.config.js', 'vitest.config.js',
];

const STRIP_DIST_ENTRIES = [
  // Vite copies these upstream documentation/build-helper files from public/.
  // The compiled application has no references to them.
  'screenshots', 'convert-icons.md', 'generate-icons.js',
  // Upstream CloudCLI logo files are unreferenced after the iGemini favicon,
  // manifest and notification icon patch. Do not ship a dormant blue logo
  // that browsers or future wrappers could rediscover by convention.
  'logo-32.png', 'logo-64.png', 'logo-128.png', 'logo-256.png', 'logo-512.png',
];
const DEPENDENCY_TEST_DIRECTORY_NAMES = new Set(['test', 'tests', '__tests__']);

const BUILTIN_MODULES = new Set(builtinModules.flatMap((name) => [name, `node:${name}`]));

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1];
}

function fail(message) {
  throw new Error(message);
}

function packageNameFromSpecifier(specifier) {
  if (
    !specifier
    || specifier.startsWith('.')
    || specifier.startsWith('/')
    || specifier.includes('${')
    || /\s/.test(specifier)
    || BUILTIN_MODULES.has(specifier)
    || BUILTIN_MODULES.has(specifier.split('/')[0])
  ) {
    return null;
  }
  if (specifier.startsWith('@')) return specifier.split('/').slice(0, 2).join('/');
  return specifier.split('/')[0];
}

function walkFiles(root, visit) {
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) walkFiles(full, visit);
    else if (entry.isFile()) visit(full);
  }
}

function scanServerImports(distServer) {
  const imports = new Set();
  const patterns = [
    /\bfrom\s*["']([^"']+)["']/g,
    /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g,
    /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g,
    /\bimport\s*["']([^"']+)["']/g,
  ];
  walkFiles(distServer, (file) => {
    if (!file.endsWith('.js') && !file.endsWith('.mjs') && !file.endsWith('.cjs')) return;
    const text = readFileSync(file, 'utf8');
    for (const pattern of patterns) {
      pattern.lastIndex = 0;
      let match;
      while ((match = pattern.exec(text))) {
        const packageName = packageNameFromSpecifier(match[1]);
        if (packageName) imports.add(packageName);
      }
    }
  });
  return imports;
}

function isForbidden(name) {
  return FORBIDDEN_PACKAGE.some((pattern) => pattern.test(name));
}

function resolveLockPackage(packages, fromKey, dependencyName) {
  let cursor = fromKey;
  while (cursor) {
    const candidate = `${cursor}/node_modules/${dependencyName}`;
    if (packages[candidate]) return candidate;
    cursor = path.posix.dirname(cursor);
    if (cursor === '.') cursor = '';
  }
  const rootCandidate = `node_modules/${dependencyName}`;
  return packages[rootCandidate] ? rootCandidate : null;
}

function dependencyClosure(lock, roots) {
  const packages = lock.packages;
  const keep = new Set();
  const queue = [];
  for (const name of roots) {
    const key = `node_modules/${name}`;
    if (!packages[key]) fail(`runtime dependency missing from package-lock: ${name}`);
    queue.push(key);
  }

  while (queue.length) {
    const key = queue.pop();
    if (keep.has(key)) continue;
    const metadata = packages[key];
    if (!metadata) fail(`package-lock entry disappeared: ${key}`);
    const name = metadata.name || key.slice(key.lastIndexOf('node_modules/') + 13);
    if (isForbidden(name)) continue;
    keep.add(key);

    const dependencyNames = new Set([
      ...Object.keys(metadata.dependencies || {}),
      ...Object.keys(metadata.optionalDependencies || {}),
      ...Object.keys(metadata.peerDependencies || {}),
    ]);
    for (const dependencyName of dependencyNames) {
      if (isForbidden(dependencyName)) continue;
      const dependencyKey = resolveLockPackage(packages, key, dependencyName);
      if (dependencyKey) queue.push(dependencyKey);
      else if (!(metadata.peerDependenciesMeta?.[dependencyName]?.optional)) {
        fail(`cannot resolve ${dependencyName} required by ${key}`);
      }
    }
  }
  return keep;
}

function installedPackageKeys(lock, nodeModules) {
  return Object.keys(lock.packages).filter((key) => {
    if (!key.startsWith('node_modules/')) return false;
    return existsSync(path.join(path.dirname(nodeModules), key));
  });
}

function removeUnkeptPackages(root, lock, keep, dryRun) {
  const nodeModules = path.join(root, 'node_modules');
  const removed = [];
  const keys = installedPackageKeys(lock, nodeModules)
    .filter((key) => !keep.has(key))
    .sort((a, b) => b.length - a.length);

  for (const key of keys) {
    const target = path.join(root, key);
    if (!existsSync(target)) continue;
    removed.push(key.slice(key.lastIndexOf('node_modules/') + 13));
    if (!dryRun) rmSync(target, { recursive: true, force: true });
  }
  if (!dryRun) {
    rmSync(path.join(nodeModules, '.bin'), { recursive: true, force: true });
    removeEmptyScopeDirectories(nodeModules);
  }
  return removed;
}

function removeEmptyScopeDirectories(root) {
  if (!existsSync(root)) return;
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith('@')) continue;
    const full = path.join(root, entry.name);
    if (readdirSync(full).length === 0) rmSync(full, { recursive: true, force: true });
  }
}

function keepOnlyDirectory(parent, keepName, dryRun) {
  if (!existsSync(parent)) return;
  for (const entry of readdirSync(parent, { withFileTypes: true })) {
    if (entry.name === keepName) continue;
    if (!dryRun) rmSync(path.join(parent, entry.name), { recursive: true, force: true });
  }
}

function trimNativePackages(root, platform, arch, dryRun) {
  const nodePty = path.join(root, 'node_modules/node-pty');
  keepOnlyDirectory(path.join(nodePty, 'prebuilds'), `${platform}-${arch}`, dryRun);
  for (const entry of ['build', 'deps', 'src', 'third_party', 'binding.gyp']) {
    if (!dryRun) rmSync(path.join(nodePty, entry), { recursive: true, force: true });
  }

  const bcrypt = path.join(root, 'node_modules/bcrypt');
  keepOnlyDirectory(path.join(bcrypt, 'prebuilds'), `${platform}-${arch}`, dryRun);
  for (const entry of ['build', 'src', 'binding.gyp']) {
    if (!dryRun) rmSync(path.join(bcrypt, entry), { recursive: true, force: true });
  }

  const sqlite = path.join(root, 'node_modules/better-sqlite3');
  for (const entry of ['deps', 'src', 'binding.gyp']) {
    if (!dryRun) rmSync(path.join(sqlite, entry), { recursive: true, force: true });
  }
  const sqliteBuild = path.join(sqlite, 'build');
  if (!dryRun && existsSync(sqliteBuild)) {
    for (const entry of readdirSync(sqliteBuild)) {
      if (entry !== 'Release') rmSync(path.join(sqliteBuild, entry), { recursive: true, force: true });
    }
    const release = path.join(sqliteBuild, 'Release');
    if (existsSync(release)) {
      for (const entry of readdirSync(release)) {
        if (entry !== 'better_sqlite3.node') rmSync(path.join(release, entry), { recursive: true, force: true });
      }
    }
  }
}

function stripBuildSource(root, dryRun) {
  if (dryRun) return;
  for (const entry of STRIP_ROOT_ENTRIES) {
    rmSync(path.join(root, entry), { recursive: true, force: true });
  }
  for (const entry of STRIP_DIST_ENTRIES) {
    rmSync(path.join(root, 'dist', entry), { recursive: true, force: true });
  }
  for (const entry of readdirSync(root)) {
    if (/^(?:.*\.)?(?:test|spec)\.[cm]?[jt]sx?$/.test(entry)) {
      rmSync(path.join(root, entry), { recursive: true, force: true });
    }
  }
  rmSync(path.join(root, 'node_modules', '.vite-temp'), { recursive: true, force: true });
}

function stripDependencyDevelopmentArtifacts(root, dryRun) {
  const nodeModules = path.join(root, 'node_modules');
  const removed = [];

  function visit(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (DEPENDENCY_TEST_DIRECTORY_NAMES.has(entry.name)) {
          removed.push(path.relative(nodeModules, full));
          if (!dryRun) rmSync(full, { recursive: true, force: true });
        } else {
          visit(full);
        }
      } else if (
        entry.isFile()
        && (entry.name.endsWith('.map') || /(?:^|\.)(?:test|spec)\.[cm]?[jt]sx?$/.test(entry.name))
      ) {
        removed.push(path.relative(nodeModules, full));
        if (!dryRun) rmSync(full, { force: true });
      }
    }
  }

  visit(nodeModules);
  if (!dryRun) {
    const remaining = [];
    visitForVerification(nodeModules, remaining);
    if (remaining.length) {
      fail(`dependency test/source-map payload remains: ${remaining.slice(0, 20).join(', ')}`);
    }
  }
  return removed.length;
}

function visitForVerification(directory, remaining) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (DEPENDENCY_TEST_DIRECTORY_NAMES.has(entry.name)) remaining.push(full);
      else visitForVerification(full, remaining);
    } else if (
      entry.isFile()
      && (entry.name.endsWith('.map') || /(?:^|\.)(?:test|spec)\.[cm]?[jt]sx?$/.test(entry.name))
    ) {
      remaining.push(full);
    }
  }
}

function removeEmptyDirectories(root) {
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const full = path.join(root, entry.name);
    removeEmptyDirectories(full);
    if (readdirSync(full).length === 0) rmSync(full, { recursive: true, force: true });
  }
}

function stripCompiledServerArtifacts(root, dryRun) {
  const distServer = path.join(root, 'dist-server');
  const artifacts = [];
  walkFiles(distServer, (file) => {
    const relative = path.relative(distServer, file);
    const segments = relative.split(path.sep);
    const inTestDirectory = segments.slice(0, -1).some((segment) => segment === 'test' || segment === 'tests');
    const isTestFile = /(?:^|\.)(?:test|spec)\.[cm]?js$/.test(path.basename(file));
    if (inTestDirectory || isTestFile || file.endsWith('.map')) artifacts.push(file);
  });
  if (!dryRun) {
    for (const file of artifacts) rmSync(file, { force: true });
    removeEmptyDirectories(distServer);
    const remaining = [];
    walkFiles(distServer, (file) => {
      const relative = path.relative(distServer, file);
      const segments = relative.split(path.sep);
      const inTestDirectory = segments.slice(0, -1).some((segment) => segment === 'test' || segment === 'tests');
      const isTestFile = /(?:^|\.)(?:test|spec)\.[cm]?js$/.test(path.basename(file));
      if (inTestDirectory || isTestFile || file.endsWith('.map')) remaining.push(relative);
    });
    if (remaining.length) fail(`compiled test/source-map payload remains: ${remaining.slice(0, 20).join(', ')}`);
  }
  return artifacts.length;
}

function nativeKind(file) {
  const buffer = readFileSync(file);
  if (buffer.length < 64) return null;
  if (buffer[0] === 0x7f && buffer.subarray(1, 4).toString() === 'ELF') {
    const little = buffer[5] === 1;
    const machine = little ? buffer.readUInt16LE(18) : buffer.readUInt16BE(18);
    return { format: 'ELF', arch: machine === 62 ? 'x64' : machine === 183 ? 'arm64' : `machine-${machine}` };
  }
  const magicLE = buffer.readUInt32LE(0);
  if (magicLE === 0xfeedfacf) {
    const cpu = buffer.readUInt32LE(4);
    return { format: 'Mach-O', arch: cpu === 0x01000007 ? 'x64' : cpu === 0x0100000c ? 'arm64' : `cpu-${cpu}` };
  }
  if (buffer[0] === 0x4d && buffer[1] === 0x5a) {
    const offset = buffer.readUInt32LE(0x3c);
    if (offset + 6 <= buffer.length && buffer.subarray(offset, offset + 4).toString('hex') === '50450000') {
      const machine = buffer.readUInt16LE(offset + 4);
      return { format: 'PE', arch: machine === 0x8664 ? 'x64' : machine === 0xaa64 ? 'arm64' : `machine-${machine}` };
    }
  }
  return null;
}

function verifyNativeArchitecture(root, targetArch) {
  const nativeFiles = [];
  walkFiles(path.join(root, 'node_modules'), (file) => {
    const base = path.basename(file);
    if (file.endsWith('.node') || file.endsWith('.dll') || file.endsWith('.exe') || base === 'rg' || base === 'spawn-helper') {
      const kind = nativeKind(file);
      if (kind) nativeFiles.push({ file, ...kind });
    }
  });
  const mismatches = nativeFiles.filter((entry) => entry.arch !== targetArch);
  if (mismatches.length) {
    fail(`native architecture mismatch:\n${mismatches.map((entry) => `  ${entry.arch}: ${entry.file}`).join('\n')}`);
  }
  if (!nativeFiles.some((entry) => entry.file.endsWith('.node'))) fail('no native addons found after pruning');
  return nativeFiles;
}

function verifyModuleImports(root, runtimeNode) {
  const probe = `
    const { createRequire } = require('node:module');
    const r = createRequire(${JSON.stringify(path.join(root, 'runtime-probe.cjs'))});
    for (const name of ['better-sqlite3','bcrypt','node-pty','@vscode/ripgrep']) r(name);
    Promise.all([import('@anthropic-ai/claude-agent-sdk'), import('@openai/codex-sdk')])
      .then(() => process.stdout.write('runtime imports ok\\n'))
      .catch((error) => { console.error(error); process.exit(2); });
  `;
  const result = spawnSync(runtimeNode, ['-e', probe], { cwd: root, encoding: 'utf8' });
  if (result.status !== 0) fail(`runtime import probe failed:\n${result.stdout}${result.stderr}`);
}

function main() {
  const root = path.resolve(arg('--root') || process.cwd());
  const platform = arg('--platform', process.platform);
  const arch = arg('--arch', process.arch);
  const runtimeNode = path.resolve(arg('--runtime-node', process.execPath));
  const dryRun = process.argv.includes('--dry-run');
  if (!['darwin', 'linux', 'win32'].includes(platform)) fail(`unsupported platform: ${platform}`);
  if (!['x64', 'arm64'].includes(arch)) fail(`unsupported arch: ${arch}`);

  for (const relative of ['dist', 'dist-server', 'node_modules', 'package-lock.json']) {
    if (!existsSync(path.join(root, relative))) fail(`CloudCLI build is missing ${relative}: ${root}`);
  }

  const imports = scanServerImports(path.join(root, 'dist-server'));
  const undeclared = [...imports].filter((name) => !RUNTIME_ROOTS.includes(name) && !OPTIONAL_SERVER_IMPORTS.has(name));
  if (undeclared.length) fail(`new server imports need runtime policy: ${undeclared.sort().join(', ')}`);

  const lock = JSON.parse(readFileSync(path.join(root, 'package-lock.json'), 'utf8'));
  const keep = dependencyClosure(lock, RUNTIME_ROOTS);
  const removed = removeUnkeptPackages(root, lock, keep, dryRun);
  trimNativePackages(root, platform, arch, dryRun);
  stripBuildSource(root, dryRun);
  const removedDependencyArtifactCount = stripDependencyDevelopmentArtifacts(root, dryRun);
  const removedCompiledArtifactCount = stripCompiledServerArtifacts(root, dryRun);

  let nativeFiles = [];
  if (!dryRun) {
    for (const pattern of FORBIDDEN_PACKAGE) {
      const offenders = installedPackageKeys(lock, path.join(root, 'node_modules')).filter((key) => {
        const metadata = lock.packages[key];
        const name = metadata?.name || key.slice(key.lastIndexOf('node_modules/') + 13);
        return pattern.test(name) && existsSync(path.join(root, key));
      });
      if (offenders.length) fail(`forbidden payload remains: ${offenders.join(', ')}`);
    }
    nativeFiles = verifyNativeArchitecture(root, arch);
    verifyModuleImports(root, runtimeNode);
  }

  const manifest = {
    schemaVersion: 1,
    product: 'iGemini',
    cloudcliVersion: lock.packages['']?.version || null,
    target: `${platform}-${arch}`,
    providerMode: 'single',
    retainedRoots: RUNTIME_ROOTS,
    retainedPackageCount: keep.size,
    removedPackageCount: removed.length,
    removedDependencyArtifactCount,
    removedCompiledArtifactCount,
    nativeFiles: nativeFiles.map((entry) => ({
      path: path.relative(root, entry.file).split(path.sep).join('/'),
      format: entry.format,
      arch: entry.arch,
    })),
  };
  if (!dryRun) writeFileSync(path.join(root, 'igemini-runtime-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`iGemini runtime pruner: ${error.message}\n`);
  process.exitCode = 2;
}
