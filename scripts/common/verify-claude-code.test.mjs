import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const verifier = path.join(import.meta.dirname, 'verify-claude-code.mjs');

function fixture(version = '2.1.220') {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'igemini-claude-verifier-'));
  writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ version }));
  writeFileSync(path.join(dir, 'claude'), 'test-binary');
  return dir;
}

function run(dir, ...extra) {
  return spawnSync(process.execPath, [
    verifier,
    '--package-root', dir,
    '--binary', path.join(dir, 'claude'),
    '--platform', 'linux-arm64',
    ...extra,
  ], { encoding: 'utf8' });
}

test('allows an explicitly version-only platform and reports the weaker policy', () => {
  const dir = fixture();
  try {
    const result = run(dir);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).binarySha256Pinned, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('fails closed when a binary hash is required but the platform is not pinned', () => {
  const dir = fixture();
  try {
    const result = run(dir, '--require-binary-sha256');
    assert.equal(result.status, 2);
    assert.match(result.stderr, /no pinned binary SHA-256 policy/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('rejects a package version mismatch', () => {
  const dir = fixture('2.1.219');
  try {
    const result = run(dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /version mismatch/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
