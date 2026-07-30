import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { REMOTE_CONTROL_CACHE_KEYS, sanitizeClaudeState } from './sanitize-claude-state.mjs';

function fixture() {
  return mkdtempSync(path.join(os.tmpdir(), 'igemini-claude-state-'));
}

test('removes only remote-control caches and creates a private backup', () => {
  const dir = fixture();
  try {
    const statePath = path.join(dir, '.claude.json');
    const original = {
      hasCompletedOnboarding: true,
      oauthAccount: { accountUuid: 'keep-me' },
      projects: { '/work': { hasTrustDialogAccepted: true } },
      clientDataCache: { tengu_heron_brook: 'injected' },
      clientDataCacheSlots: { slot: { data: { tengu_heron_brook: 'injected' } } },
      cachedGrowthBookFeatures: { tengu_heron_brook: 'injected' },
      cachedDynamicConfigs: { arbitrary: 'remote' },
    };
    writeFileSync(statePath, JSON.stringify(original), { mode: 0o600 });
    chmodSync(statePath, 0o644); // sanitizer must tighten historical world-readable state

    const result = sanitizeClaudeState(dir, { now: new Date('2026-07-30T00:00:00.000Z') });
    assert.equal(result.status, 'sanitized');
    assert.deepEqual(result.removedKeys.sort(), [
      'cachedDynamicConfigs',
      'cachedGrowthBookFeatures',
      'clientDataCache',
      'clientDataCacheSlots',
    ]);

    const sanitized = JSON.parse(readFileSync(statePath, 'utf8'));
    for (const key of REMOTE_CONTROL_CACHE_KEYS) assert.equal(key in sanitized, false);
    assert.deepEqual(sanitized.oauthAccount, original.oauthAccount);
    assert.deepEqual(sanitized.projects, original.projects);
    assert.equal(sanitized.hasCompletedOnboarding, true);
    assert.deepEqual(JSON.parse(readFileSync(result.backupPath, 'utf8')), original);
    assert.equal(statSync(statePath).mode & 0o777, 0o600);
    assert.equal(statSync(result.backupPath).mode & 0o777, 0o600);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('does not create backups for a clean state file', () => {
  const dir = fixture();
  try {
    writeFileSync(path.join(dir, '.claude.json'), JSON.stringify({ theme: 'dark' }), { mode: 0o600 });
    const result = sanitizeClaudeState(dir);
    assert.equal(result.status, 'clean');
    assert.deepEqual(readdirSync(dir), ['.claude.json']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('fails closed and leaves malformed state untouched', () => {
  const dir = fixture();
  try {
    const statePath = path.join(dir, '.claude.json');
    writeFileSync(statePath, '{ malformed', { mode: 0o600 });
    assert.throws(() => sanitizeClaudeState(dir), /refusing to rewrite malformed/);
    assert.equal(readFileSync(statePath, 'utf8'), '{ malformed');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
