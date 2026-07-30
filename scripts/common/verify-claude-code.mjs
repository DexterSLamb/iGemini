#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const release = JSON.parse(readFileSync(path.join(scriptDir, 'claude-code-release.json'), 'utf8'));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function sha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function main() {
  const packageRoot = argument('--package-root');
  const binary = argument('--binary');
  const platform = argument('--platform') || `${process.platform}-${process.arch}`;
  const requireBinarySha256 = process.argv.includes('--require-binary-sha256');
  if (!packageRoot) throw new Error('--package-root is required');

  const packageJson = JSON.parse(readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
  if (packageJson.version !== release.version) {
    throw new Error(`Claude Code version mismatch: expected ${release.version}, got ${packageJson.version}`);
  }

  const platformPolicy = release.platforms[platform];
  if (requireBinarySha256 && !platformPolicy?.binarySha256) {
    throw new Error(`no pinned binary SHA-256 policy for required platform ${platform}`);
  }
  if (platformPolicy?.binarySha256) {
    if (!binary) throw new Error(`--binary is required for pinned platform ${platform}`);
    const actual = await sha256(binary);
    if (actual !== platformPolicy.binarySha256) {
      throw new Error(`Claude Code ${platform} SHA-256 mismatch: expected ${platformPolicy.binarySha256}, got ${actual}`);
    }
  }

  process.stdout.write(`${JSON.stringify({
    status: 'verified',
    version: packageJson.version,
    platform,
    binarySha256Pinned: Boolean(platformPolicy?.binarySha256),
  })}\n`);
}

main().catch((error) => {
  process.stderr.write(`iGemini Claude verifier: ${error.message}\n`);
  process.exitCode = 2;
});
