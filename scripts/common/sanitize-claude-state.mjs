#!/usr/bin/env node

import {
  chmodSync,
  closeSync,
  copyFileSync,
  existsSync,
  fsyncSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REMOTE_CONTROL_CACHE_KEYS = Object.freeze([
  'clientDataCache',
  'clientDataCacheSlots',
  'cachedGrowthBookFeatures',
  'cachedGrowthBookFeaturesAt',
  'cachedExperimentFeatures',
  'cachedExperimentData',
  'cachedDynamicConfigs',
]);

function safeTimestamp(now) {
  return now.toISOString().replace(/[:.]/g, '-');
}

export function sanitizeClaudeState(configDir, options = {}) {
  if (!configDir || typeof configDir !== 'string') {
    throw new TypeError('CLAUDE_CONFIG_DIR is required');
  }

  const statePath = path.join(configDir, '.claude.json');
  if (!existsSync(statePath)) {
    return { status: 'missing', statePath, removedKeys: [], backupPath: null };
  }

  const original = readFileSync(statePath, 'utf8');
  let state;
  try {
    state = JSON.parse(original);
  } catch (error) {
    throw new Error(`refusing to rewrite malformed Claude state ${statePath}: ${error.message}`);
  }
  if (state === null || Array.isArray(state) || typeof state !== 'object') {
    throw new Error(`refusing to rewrite non-object Claude state ${statePath}`);
  }

  const removedKeys = REMOTE_CONTROL_CACHE_KEYS.filter((key) =>
    Object.prototype.hasOwnProperty.call(state, key));
  if (removedKeys.length === 0) {
    return { status: 'clean', statePath, removedKeys, backupPath: null };
  }

  const now = options.now ?? new Date();
  const backupPath = `${statePath}.igemini-security-backup-${safeTimestamp(now)}-${process.pid}`;
  const tempPath = `${statePath}.igemini-security-tmp-${process.pid}`;
  const originalMode = statSync(statePath).mode & 0o777;
  const restrictedMode = (originalMode & 0o600) || 0o600;

  copyFileSync(statePath, backupPath);
  chmodSync(backupPath, 0o600);
  for (const key of removedKeys) delete state[key];

  const payload = `${JSON.stringify(state, null, 2)}\n`;
  let descriptor;
  try {
    descriptor = openSync(tempPath, 'wx', restrictedMode);
    writeFileSync(descriptor, payload, 'utf8');
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(tempPath, statePath);
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    try { unlinkSync(tempPath); } catch {}
    throw error;
  }

  return { status: 'sanitized', statePath, removedKeys, backupPath };
}

function isMainModule() {
  if (!process.argv[1]) return false;
  return fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
}

if (isMainModule()) {
  try {
    const result = sanitizeClaudeState(process.argv[2] || process.env.CLAUDE_CONFIG_DIR);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`iGemini security sanitizer: ${error.message}\n`);
    process.exitCode = 2;
  }
}
