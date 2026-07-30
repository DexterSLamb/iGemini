#!/usr/bin/env python3
"""Shape CloudCLI into the iGemini product without deleting future capabilities.

The original multi-provider UI remains behind the build-time switch
VITE_IGEMINI_MULTI_PROVIDER=1. Release builds leave it unset, so stale browser
preferences cannot make a new session select a provider whose native payload is
intentionally not bundled. The product build also retains the earlier native
system font stack instead of loading CloudCLI's newer Google-hosted web fonts.
Upstream promotional surfaces and its self-update command are replaced with
iGemini-owned release links and read-only product information.
"""

from __future__ import annotations

from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise AssertionError(
            f"single-provider patch anchor mismatch: {path} "
            f"(expected 1, found {count})"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_exact(path: Path, old: str, new: str, expected: int) -> None:
    text = path.read_text(encoding="utf-8")
    if text.count(new) == expected and old not in text:
        return
    count = text.count(old)
    if count != expected:
        raise AssertionError(
            f"product-surface patch anchor mismatch: {path} "
            f"(expected {expected}, found {count})"
        )
    path.write_text(text.replace(old, new), encoding="utf-8")


def remove_once(path: Path, old: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count == 0:
        return
    if count != 1:
        raise AssertionError(
            f"product-surface removal anchor mismatch: {path} "
            f"(expected 1, found {count})"
        )
    path.write_text(text.replace(old, "", 1), encoding="utf-8")


def rewrite_file(path: Path, required_markers: tuple[str, ...], done_marker: str, content: str) -> None:
    text = path.read_text(encoding="utf-8")
    if done_marker in text:
        return
    missing = [marker for marker in required_markers if marker not in text]
    if missing:
        raise AssertionError(
            f"product-surface rewrite anchor mismatch: {path} "
            f"(missing {missing})"
        )
    path.write_text(content, encoding="utf-8")


def patch_product_surface(root: Path) -> None:
    """Replace upstream promotions/update actions while preserving native styling."""

    github_repo = "https://github.com/DexterSLamb/iGemini"

    version_hook = root / "src/hooks/useVersionCheck.ts"
    replace_once(
        version_hook,
        "import { ReleaseInfo } from '../types/sharedTypes';\n",
        "import { ReleaseInfo } from '../types/sharedTypes';\n\n"
        "// Product releases use their own version stream; package.json continues\n"
        "// to describe the pinned CloudCLI implementation underneath iGemini.\n"
        "const IGEMINI_VERSION = import.meta.env.VITE_IGEMINI_VERSION || version;\n"
        "const VERSION_CHECK_INTERVAL_MS = 12 * 60 * 60 * 1000;\n\n"
        "type GitHubReleasePayload = {\n"
        "  tag_name?: string;\n"
        "  name?: string;\n"
        "  body?: string;\n"
        "  html_url?: string;\n"
        "  published_at: string;\n"
        "};\n\n"
        "type ReleaseCache = {\n"
        "  key: string;\n"
        "  checkedAt: number;\n"
        "  data: GitHubReleasePayload;\n"
        "};\n\n"
        "let releaseCache: ReleaseCache | null = null;\n"
        "let releaseRequest: { key: string; promise: Promise<GitHubReleasePayload> } | null = null;\n\n"
        "const fetchLatestRelease = async (owner: string, repo: string): Promise<GitHubReleasePayload> => {\n"
        "  const key = `${owner}/${repo}`;\n"
        "  const now = Date.now();\n"
        "  if (releaseCache?.key === key && now - releaseCache.checkedAt < VERSION_CHECK_INTERVAL_MS) {\n"
        "    return releaseCache.data;\n"
        "  }\n"
        "  if (releaseRequest?.key === key) return releaseRequest.promise;\n\n"
        "  const promise = fetch(`https://api.github.com/repos/${owner}/${repo}/releases/latest`).then(async (response) => {\n"
        "    if (!response.ok) throw new Error(`GitHub releases request failed: ${response.status}`);\n"
        "    return (await response.json()) as GitHubReleasePayload;\n"
        "  });\n"
        "  releaseRequest = { key, promise };\n"
        "  try {\n"
        "    const data = await promise;\n"
        "    releaseCache = { key, checkedAt: Date.now(), data };\n"
        "    return data;\n"
        "  } finally {\n"
        "    if (releaseRequest?.promise === promise) releaseRequest = null;\n"
        "  }\n"
        "};\n",
    )
    replace_once(
        version_hook,
        "setUpdateAvailable(compareVersions(latest, version) > 0);",
        "setUpdateAvailable(compareVersions(latest, IGEMINI_VERSION) > 0);",
    )
    replace_once(
        version_hook,
        "const response = await fetch(`https://api.github.com/repos/${owner}/${repo}/releases/latest`);\n"
        "        const data = await response.json();",
        "const data = await fetchLatestRelease(owner, repo);",
    )
    replace_once(
        version_hook,
        "const interval = setInterval(checkVersion, 5 * 60 * 1000); // Check every 5 minutes",
        "const interval = setInterval(checkVersion, VERSION_CHECK_INTERVAL_MS); // Check every 12 hours",
    )
    replace_once(
        version_hook,
        "return { updateAvailable, latestVersion, currentVersion: version, releaseInfo, installMode, runningVersion, restartRequired };",
        "return { updateAvailable, latestVersion, currentVersion: IGEMINI_VERSION, releaseInfo, installMode, runningVersion, restartRequired };",
    )

    about_tab = """import { ExternalLink, HardDrive, PackageCheck, ShieldCheck, Star } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { CLOUDCLI_WORDMARK_FONT_FAMILY } from '../../../../constants/branding';
import { useVersionCheck } from '../../../../hooks/useVersionCheck';

const GITHUB_REPO_URL = 'https://github.com/DexterSLamb/iGemini';
const RELEASES_URL = `${GITHUB_REPO_URL}/releases`;
const README_URL = `${GITHUB_REPO_URL}#readme`;
const LICENSE_URL = `${GITHUB_REPO_URL}/blob/main/LICENSE`;

function GitHubIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" />
    </svg>
  );
}

export default function AboutTab() {
  const { t } = useTranslation('settings');
  const { updateAvailable, latestVersion, currentVersion, releaseInfo } = useVersionCheck('DexterSLamb', 'iGemini');
  const latestReleaseUrl = releaseInfo?.htmlUrl || (
    latestVersion ? `${RELEASES_URL}/tag/v${latestVersion.replace(/^v/, '')}` : RELEASES_URL
  );

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <img src="/igemini.png" alt="iGemini" className="h-10 w-10 flex-shrink-0 rounded-xl shadow-sm" />
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span
              className="text-base font-semibold text-foreground"
              style={{ fontFamily: CLOUDCLI_WORDMARK_FONT_FAMILY }}
            >
              iGemini
            </span>
            <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">
              v{currentVersion}
            </span>
            {updateAvailable && latestVersion && (
              <a
                href={latestReleaseUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-1 rounded-full bg-green-500/10 px-2 py-0.5 text-[10px] font-medium text-green-600 transition-colors hover:bg-green-500/20 dark:text-green-400"
              >
                {t('apiKeys.version.updateAvailable', { version: latestVersion })}
                <ExternalLink className="h-2.5 w-2.5" />
              </a>
            )}
          </div>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Your local-first AI work partner
          </p>
        </div>
      </div>

      <a
        href={GITHUB_REPO_URL}
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex items-center gap-2 rounded-lg border border-border/60 bg-background px-3.5 py-2 text-sm font-medium text-muted-foreground transition-colors hover:bg-muted/50 hover:text-foreground"
      >
        <GitHubIcon className="h-4 w-4" />
        <Star className="h-3.5 w-3.5" />
        <span>Star on GitHub</span>
      </a>

      <div className="flex flex-wrap gap-4 text-sm">
        <a
          href={GITHUB_REPO_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-1.5 text-muted-foreground transition-colors hover:text-foreground"
        >
          <GitHubIcon className="h-4 w-4" />
          GitHub
        </a>
        <a
          href={RELEASES_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-1.5 text-muted-foreground transition-colors hover:text-foreground"
        >
          <ExternalLink className="h-3.5 w-3.5" />
          Releases
        </a>
        <a
          href={README_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-1.5 text-muted-foreground transition-colors hover:text-foreground"
        >
          <ExternalLink className="h-3.5 w-3.5" />
          Documentation
        </a>
      </div>

      <div className="rounded-xl border border-primary/10 bg-primary/5 p-4">
        <div className="flex items-start gap-3">
          <ShieldCheck className="mt-0.5 h-5 w-5 flex-shrink-0 text-primary" />
          <div>
            <h4 className="text-sm font-medium text-foreground">Open source and local-first</h4>
            <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
              Your keys, configuration, and sessions stay in your iGemini environment. Source code and release notes are published on GitHub.
            </p>
          </div>
        </div>
      </div>

      <div className="space-y-3 border-t border-border/50 pt-6">
        <h3 className="text-sm font-medium text-foreground">Built into iGemini</h3>
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="rounded-xl border border-border/60 bg-muted/20 p-4">
            <div className="flex items-start gap-3">
              <div className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg bg-muted/60 text-muted-foreground">
                <HardDrive className="h-5 w-5" />
              </div>
              <div>
                <h4 className="text-sm font-medium text-foreground">Local workspace</h4>
                <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                  Work with your own projects and keep product state under your control.
                </p>
              </div>
            </div>
          </div>
          <div className="rounded-xl border border-border/60 bg-muted/20 p-4">
            <div className="flex items-start gap-3">
              <div className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg bg-muted/60 text-muted-foreground">
                <PackageCheck className="h-5 w-5" />
              </div>
              <div>
                <h4 className="text-sm font-medium text-foreground">Verified releases</h4>
                <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                  Platform installers are built from pinned and integrity-checked inputs.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div className="border-t border-border/50 pt-4">
        <a
          href={LICENSE_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-muted-foreground/60 transition-colors hover:text-muted-foreground"
        >
          Licensed under AGPL-3.0
        </a>
      </div>
    </div>
  );
}
"""
    rewrite_file(
        root / "src/components/settings/view/tabs/AboutTab.tsx",
        ("Try iGemini Hosted", "iGemini Pro Features", "siteboon/claudecodeui"),
        "Open source and local-first",
        about_tab,
    )

    version_section = """import { ExternalLink, ShieldCheck, Star } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import { CLOUDCLI_WORDMARK_FONT_FAMILY } from '../../../../../../constants/branding';
import type { ReleaseInfo } from '../../../../../../types/sharedTypes';

const GITHUB_REPO_URL = 'https://github.com/DexterSLamb/iGemini';
const RELEASES_URL = `${GITHUB_REPO_URL}/releases`;
const README_URL = `${GITHUB_REPO_URL}#readme`;

function GitHubIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" />
    </svg>
  );
}

type VersionInfoSectionProps = {
  currentVersion: string;
  updateAvailable: boolean;
  latestVersion: string | null;
  releaseInfo: ReleaseInfo | null;
};

export default function VersionInfoSection({
  currentVersion,
  updateAvailable,
  latestVersion,
  releaseInfo,
}: VersionInfoSectionProps) {
  const { t } = useTranslation('settings');
  const latestReleaseUrl = releaseInfo?.htmlUrl || (
    latestVersion ? `${RELEASES_URL}/tag/v${latestVersion.replace(/^v/, '')}` : RELEASES_URL
  );

  return (
    <div className="border-t border-border/50 pt-6">
      <div className="space-y-4">
        <div className="flex items-center gap-3">
          <img src="/igemini.png" alt="iGemini" className="h-9 w-9 flex-shrink-0 rounded-lg shadow-sm" />
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <span
                className="text-sm font-semibold text-foreground"
                style={{ fontFamily: CLOUDCLI_WORDMARK_FONT_FAMILY }}
              >
                iGemini
              </span>
              <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] font-medium text-muted-foreground">
                v{currentVersion}
              </span>
              {updateAvailable && latestVersion && (
                <a
                  href={latestReleaseUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="flex items-center gap-1 rounded-full bg-green-500/10 px-2 py-0.5 text-[10px] font-medium text-green-600 transition-colors hover:bg-green-500/20 dark:text-green-400"
                >
                  {t('apiKeys.version.updateAvailable', { version: latestVersion })}
                  <ExternalLink className="h-2.5 w-2.5" />
                </a>
              )}
            </div>
            <p className="mt-0.5 text-xs text-muted-foreground">Your local-first AI work partner</p>
          </div>
        </div>

        <div className="flex flex-wrap gap-3 text-xs">
          <a
            href={GITHUB_REPO_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1 text-muted-foreground transition-colors hover:text-foreground"
          >
            <GitHubIcon className="h-3.5 w-3.5" />
            GitHub
          </a>
          <a
            href={RELEASES_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1 text-muted-foreground transition-colors hover:text-foreground"
          >
            <ExternalLink className="h-3 w-3" />
            Releases
          </a>
          <a
            href={README_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1 text-muted-foreground transition-colors hover:text-foreground"
          >
            <ExternalLink className="h-3 w-3" />
            Documentation
          </a>
        </div>

        <div className="rounded-xl border border-primary/10 bg-primary/5 p-4">
          <div className="flex items-start gap-3">
            <ShieldCheck className="mt-0.5 h-4 w-4 flex-shrink-0 text-primary" />
            <div>
              <h4 className="text-sm font-medium text-foreground">Open source and local-first</h4>
              <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                Source code, release notes, and verified installers are available from the iGemini repository.
              </p>
            </div>
          </div>
        </div>

        <a
          href={GITHUB_REPO_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-2 rounded-lg border border-border/60 bg-background px-3 py-1.5 text-xs font-medium text-muted-foreground transition-colors hover:bg-muted/50 hover:text-foreground"
        >
          <GitHubIcon className="h-4 w-4" />
          <Star className="h-3.5 w-3.5" />
          <span>Star on GitHub</span>
        </a>
      </div>
    </div>
  );
}
"""
    rewrite_file(
        root / "src/components/settings/view/tabs/api-settings/sections/VersionInfoSection.tsx",
        ("Try iGemini Hosted", "siteboon/claudecodeui", "cloudcli.ai"),
        "Source code, release notes, and verified installers",
        version_section,
    )

    sidebar_footer = """import { AlertTriangle, ArrowUpCircle, Settings } from 'lucide-react';
import type { TFunction } from 'i18next';
import type { ReleaseInfo } from '../../../../types/sharedTypes';

type SidebarFooterProps = {
  updateAvailable: boolean;
  restartRequired: boolean;
  releaseInfo: ReleaseInfo | null;
  latestVersion: string | null;
  currentVersion: string;
  onShowVersionModal: () => void;
  onShowSettings: () => void;
  t: TFunction;
};

export default function SidebarFooter({
  updateAvailable,
  restartRequired,
  releaseInfo,
  latestVersion,
  onShowVersionModal,
  onShowSettings,
  t,
}: SidebarFooterProps) {
  return (
    <div className="flex-shrink-0" style={{ paddingBottom: 'env(safe-area-inset-bottom, 0)' }}>
      {/* [iGemini] Product update status. Product installers remain user-managed. */}
      {restartRequired && (
        <>
          <div className="nav-divider" />
          <div className="px-2 py-1.5">
            <div className="flex items-center gap-2.5 rounded-lg border border-amber-300/60 bg-amber-50/80 px-2.5 py-2 dark:border-amber-700/40 dark:bg-amber-900/15">
              <AlertTriangle className="h-4 w-4 flex-shrink-0 text-amber-500 dark:text-amber-400" />
              <span className="min-w-0 flex-1 text-xs font-medium text-amber-700 dark:text-amber-300">
                {t('version.restartRequired')}
              </span>
            </div>
          </div>
        </>
      )}

      {updateAvailable && (
        <>
          <div className="nav-divider" />
          <div className="hidden px-2 py-1.5 md:block">
            <button
              className="group flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors hover:bg-blue-50/80 dark:hover:bg-blue-900/15"
              onClick={onShowVersionModal}
            >
              <div className="relative flex-shrink-0">
                <ArrowUpCircle className="h-4 w-4 text-blue-500 dark:text-blue-400" />
                <span className="absolute -right-0.5 -top-0.5 h-1.5 w-1.5 animate-pulse rounded-full bg-blue-500" />
              </div>
              <div className="min-w-0 flex-1">
                <span className="block truncate text-sm font-normal text-blue-600 dark:text-blue-300">
                  {releaseInfo?.title || (latestVersion ? `iGemini v${latestVersion}` : 'iGemini update')}
                </span>
                <span className="text-[10px] text-blue-500/70 dark:text-blue-400/60">
                  {t('version.updateAvailable')}
                </span>
              </div>
            </button>
          </div>

          <div className="px-3 py-2 md:hidden">
            <button
              className="flex h-11 w-full items-center gap-3 rounded-xl border border-blue-200/60 bg-blue-50/80 px-3.5 transition-all active:scale-[0.98] dark:border-blue-700/40 dark:bg-blue-900/15"
              onClick={onShowVersionModal}
            >
              <div className="relative flex-shrink-0">
                <ArrowUpCircle className="h-4 w-4 text-blue-500 dark:text-blue-400" />
                <span className="absolute -right-0.5 -top-0.5 h-1.5 w-1.5 animate-pulse rounded-full bg-blue-500" />
              </div>
              <div className="min-w-0 flex-1 text-left">
                <span className="block truncate text-sm font-normal text-blue-600 dark:text-blue-300">
                  {releaseInfo?.title || (latestVersion ? `iGemini v${latestVersion}` : 'iGemini update')}
                </span>
                <span className="text-xs text-blue-500/70 dark:text-blue-400/60">
                  {t('version.updateAvailable')}
                </span>
              </div>
            </button>
          </div>
        </>
      )}

      <div className="nav-divider" />
      <div className="hidden px-2 py-1.5 md:block">
        <button
          className="flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
          onClick={onShowSettings}
        >
          <Settings className="h-3.5 w-3.5" />
          <span className="text-sm">{t('actions.settings')}</span>
        </button>
      </div>

      <div className="px-3 pb-3 pt-3 md:hidden">
        <button
          className="flex h-10 w-full items-center gap-3 rounded-xl bg-muted/40 px-3.5 transition-all hover:bg-muted/60 active:scale-[0.98]"
          onClick={onShowSettings}
        >
          <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-background/80">
            <Settings className="h-4 w-4 text-muted-foreground" />
          </div>
          <span className="text-sm font-normal text-foreground">{t('actions.settings')}</span>
        </button>
      </div>
    </div>
  );
}
"""
    rewrite_file(
        root / "src/components/sidebar/view/subcomponents/SidebarFooter.tsx",
        (
            "export default function SidebarFooter({ onShowSettings, t }: SidebarFooterProps)",
            "{/* Desktop settings */}",
            "{/* Mobile settings */}",
        ),
        "[iGemini] Product update status",
        sidebar_footer,
    )

    neutral_feature_card = """import type { ReactNode } from 'react';

type ProductFeatureCardProps = {
  icon: ReactNode;
  title: string;
  description: string;
};

export default function ProductFeatureCard({
  icon,
  title,
  description,
}: ProductFeatureCardProps) {
  return (
    <div className="rounded-xl border border-border/60 bg-muted/20 p-5">
      <div className="flex items-start gap-3">
        <div className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg bg-muted/60 text-muted-foreground">
          {icon}
        </div>
        <div className="min-w-0 flex-1">
          <h4 className="text-sm font-medium text-foreground">{title}</h4>
          <p className="mt-1 text-xs leading-relaxed text-muted-foreground">{description}</p>
        </div>
      </div>
    </div>
  );
}
"""
    rewrite_file(
        root / "src/components/settings/view/PremiumFeatureCard.tsx",
        ("Available with iGemini Pro", "https://cloudcli.ai", "Lock"),
        "type ProductFeatureCardProps",
        neutral_feature_card,
    )

    upgrade_modal = """import type { ReactNode } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { useTranslation } from 'react-i18next';

import type { InstallMode } from '../../../hooks/useVersionCheck';
import type { ReleaseInfo } from '../../../types/sharedTypes';

interface VersionUpgradeModalProps {
  isOpen: boolean;
  onClose: () => void;
  releaseInfo: ReleaseInfo | null;
  currentVersion: string;
  latestVersion: string | null;
  installMode: InstallMode;
}

const IGEMINI_RELEASES_URL = 'https://github.com/DexterSLamb/iGemini/releases';

export function VersionUpgradeModal({
  isOpen,
  onClose,
  releaseInfo,
  currentVersion,
  latestVersion,
}: VersionUpgradeModalProps) {
  const { t } = useTranslation('common');

  if (!isOpen) return null;

  const releaseUrl = releaseInfo?.htmlUrl || IGEMINI_RELEASES_URL;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <button
        className="fixed inset-0 bg-black/50 backdrop-blur-sm"
        onClick={onClose}
        aria-label={t('versionUpdate.ariaLabels.closeModal')}
      />

      <div className="relative mx-4 max-h-[90vh] w-full max-w-2xl space-y-5 overflow-y-auto rounded-xl border border-border bg-card p-6 shadow-xl">
        <div className="flex items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary">
              <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M9 19l3 3m0 0l3-3m-3 3V10" />
              </svg>
            </div>
            <div>
              <h2 className="text-lg font-semibold text-foreground">{t('versionUpdate.title')}</h2>
              <p className="text-sm text-muted-foreground">
                {releaseInfo?.title || t('versionUpdate.newVersionReady')}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="rounded-md p-2 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            aria-label={t('versionUpdate.ariaLabels.closeModal')}
          >
            <svg className="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          <div className="rounded-lg bg-muted/50 p-3">
            <span className="text-sm font-medium text-muted-foreground">{t('versionUpdate.currentVersion')}</span>
            <div className="mt-1 font-mono text-sm text-foreground">{currentVersion}</div>
          </div>
          <div className="rounded-lg border border-primary/20 bg-primary/5 p-3">
            <span className="text-sm font-medium text-primary">{t('versionUpdate.latestVersion')}</span>
            <div className="mt-1 font-mono text-sm text-foreground">{latestVersion}</div>
          </div>
        </div>

        {releaseInfo?.body && (
          <div className="space-y-3">
            <h3 className="text-sm font-medium text-foreground">{t('versionUpdate.whatsNew')}</h3>
            <div className="max-h-64 overflow-y-auto rounded-lg border border-border bg-muted/30 p-4">
              <div className="prose prose-sm max-w-none text-sm text-muted-foreground dark:prose-invert">
                <ReactMarkdown remarkPlugins={[remarkGfm]} components={changelogComponents}>
                  {cleanChangelog(releaseInfo.body)}
                </ReactMarkdown>
              </div>
            </div>
          </div>
        )}

        <p className="text-xs leading-relaxed text-muted-foreground">
          iGemini installers are platform-specific. Open Releases to review the notes and download the correct package for this device.
        </p>

        <div className="flex flex-col gap-2 pt-1 sm:flex-row sm:justify-end">
          <button
            onClick={onClose}
            className="rounded-md bg-muted px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-muted/80"
          >
            {t('versionUpdate.buttons.later')}
          </button>
          <a
            href={releaseUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center justify-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Open iGemini Releases
            <svg className="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M14 5h5m0 0v5m0-5L10 14M19 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V7a2 2 0 012-2h6" />
            </svg>
          </a>
        </div>
      </div>
    </div>
  );
}

const changelogComponents = {
  a: ({ href, children }: { href?: string; children?: ReactNode }) => (
    <a href={href} target="_blank" rel="noopener noreferrer" className="text-primary hover:underline">
      {children}
    </a>
  ),
};

const cleanChangelog = (body: string) => {
  if (!body) return '';

  return body
    .replace(/\\b[0-9a-f]{40}\\b/gi, '')
    .replace(/(?:^|\\s|-)([0-9a-f]{7,10})\\b/gi, '')
    .replace(/\\*\\*Full Changelog\\*\\*:.*$/gim, '')
    .replace(/https?:\\/\\/github\\.com\\/[^\\/]+\\/[^\\/]+\\/compare\\/[^\\s)]+/gi, '')
    .replace(/\\n\\s*\\n\\s*\\n/g, '\\n\\n')
    .trim();
};
"""
    rewrite_file(
        root / "src/components/version-upgrade/view/VersionUpgradeModal.tsx",
        ("authenticatedFetch('/api/system/update'", "git checkout main && git pull", "handleUpdateNow"),
        "Open iGemini Releases",
        upgrade_modal,
    )

    server_index = root / "server/index.js"
    server_text = server_index.read_text(encoding="utf-8")
    disabled_update_marker = (
        "// iGemini updates are installer-managed; no runtime update endpoint is registered."
    )
    if disabled_update_marker not in server_text:
        update_start = "// System update endpoint\n"
        update_end = "\nconst expandWorkspacePath ="
        if server_text.count(update_start) != 1 or server_text.count(update_end) != 1:
            raise AssertionError(f"product-surface update endpoint anchor mismatch: {server_index}")
        before, rest = server_text.split(update_start, 1)
        _, after = rest.split(update_end, 1)
        server_index.write_text(
            before + disabled_update_marker + "\n\nconst expandWorkspacePath =" + after,
            encoding="utf-8",
        )
    remove_once(
        server_index,
        "// cross-spawn is a drop-in for child_process.spawn that resolves .cmd\n"
        "// shims/PATHEXT on Windows and delegates to the native spawn elsewhere.\n"
        "import spawn from 'cross-spawn';\n",
    )

    server_cli = root / "server/cli.js"
    replace_once(
        server_cli,
        "console.log(`\\n${c.info('[INFO]')} Version: ${c.bright(packageJson.version)}`);",
        "console.log(`\\n${c.info('[INFO]')} CloudCLI engine version: ${c.bright(packageJson.version)}`);",
    )
    replace_once(
        server_cli,
        "  update           Update to the latest version",
        "  update           Show the iGemini Releases page",
    )
    replace_once(
        server_cli,
        "  ${packageJson.homepage || 'https://github.com/siteboon/claudecodeui'}",
        f"  {github_repo}#readme",
    )
    replace_once(
        server_cli,
        "  ${packageJson.bugs?.url || 'https://github.com/siteboon/claudecodeui/issues'}",
        f"  {github_repo}/issues",
    )
    cli_text = server_cli.read_text(encoding="utf-8")
    release_only_marker = "iGemini updates are distributed as platform-specific installers."
    if release_only_marker not in cli_text:
        update_logic_start = "// Compare semver versions, returns true if v1 > v2\n"
        update_logic_end = "\n// ── Sandbox command"
        if cli_text.count(update_logic_start) != 1 or cli_text.count(update_logic_end) != 1:
            raise AssertionError(f"product-surface CLI update anchor mismatch: {server_cli}")
        before, rest = cli_text.split(update_logic_start, 1)
        _, after = rest.split(update_logic_end, 1)
        release_only = (
            "// iGemini never mutates its pinned CloudCLI engine at runtime.\n"
            "async function updatePackage() {\n"
            f"    console.log('{release_only_marker}');\n"
            f"    console.log('{github_repo}/releases');\n"
            "}\n"
        )
        server_cli.write_text(
            before + release_only + "\n// ── Sandbox command" + after,
            encoding="utf-8",
        )
    replace_once(
        server_cli,
        "console.log(`\\n${c.dim('  Or install globally:')} npm install -g @cloudcli-ai/cloudcli\\n`);",
        f"console.log(`\\n${{c.dim('  iGemini installers:')}} {github_repo}/releases\\n`);",
    )
    replace_once(
        server_cli,
        "async function startServer() {\n"
        "    // Check for updates silently on startup\n"
        "    checkForUpdates(true);\n\n"
        "    // Import and run the server\n",
        "async function startServer() {\n"
        "    // Product updates are installer-managed; do not query npm on startup.\n",
    )

    mcp_servers = root / "src/components/mcp/view/McpServers.tsx"
    replace_once(
        mcp_servers,
        "import { Edit3, ExternalLink, Globe, Lock, Plus, Server, Terminal, Trash2, Users, Zap } from 'lucide-react';",
        "import { Edit3, Globe, Lock, Plus, Server, Terminal, Trash2, Zap } from 'lucide-react';",
    )
    remove_once(
        mcp_servers,
        "import { IS_PLATFORM } from '../../../constants/config';\n",
    )
    team_card_start = "function TeamMcpFeatureCard() {\n"
    team_card_end = "\nexport default function McpServers"
    mcp_text = mcp_servers.read_text(encoding="utf-8")
    if team_card_start in mcp_text:
        before, rest = mcp_text.split(team_card_start, 1)
        _, after = rest.split(team_card_end, 1)
        mcp_servers.write_text(before + "export default function McpServers" + after, encoding="utf-8")
    elif "Team MCP Configs" in mcp_text:
        raise AssertionError(f"product-surface Team MCP anchor mismatch: {mcp_servers}")
    remove_once(
        mcp_servers,
        "\n      {selectedProvider === 'claude' && !IS_PLATFORM && <TeamMcpFeatureCard />}\n",
    )

    replace_once(
        root / "src/components/auth/view/AuthScreenLayout.tsx",
        'href="https://github.com/siteboon/claudecodeui"',
        f'href="{github_repo}"',
    )
    star_badge = root / "src/components/sidebar/view/subcomponents/GitHubStarBadge.tsx"
    replace_once(
        star_badge,
        "const GITHUB_REPO_URL = 'https://github.com/siteboon/claudecodeui';",
        f"const GITHUB_REPO_URL = '{github_repo}';",
    )
    replace_once(
        star_badge,
        "useGitHubStars('siteboon', 'claudecodeui')",
        "useGitHubStars('DexterSLamb', 'iGemini')",
    )
    replace_once(
        root / "src/components/sidebar/view/Sidebar.tsx",
        "    'siteboon',\n    'claudecodeui',",
        "    'DexterSLamb',\n    'iGemini',",
    )
    replace_once(
        root / "src/components/plugins/view/PluginSettingsTab.tsx",
        'href="https://cloudcli.ai/docs/plugin-overview"',
        f'href="{github_repo}#readme"',
    )
    replace_exact(
        root / "src/components/sidebar/view/subcomponents/SidebarHeader.tsx",
        'href="https://cloudcli.ai/dashboard"',
        f'href="{github_repo}"',
        2,
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-cloudcli-single-provider.py <cloudcli-root>")

    root = Path(sys.argv[1]).resolve()
    state = root / "src/hooks/useProjectsState.ts"
    empty_state = root / "src/components/chat/view/subcomponents/ProviderSelectionEmptyState.tsx"
    agents = root / "src/components/settings/view/tabs/agents-settings/AgentsSettingsTab.tsx"
    onboarding_agents = root / "src/components/onboarding/view/subcomponents/AgentConnectionsStep.tsx"
    onboarding_progress = root / "src/components/onboarding/view/subcomponents/OnboardingStepProgress.tsx"

    replace_once(
        root / "index.html",
        """    <!-- Fonts: Encode Sans (UI) + Merriweather (chat) -->
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
      href="https://fonts.googleapis.com/css2?family=Encode+Sans:wght@400;500;600;700&family=Merriweather:ital,wght@0,400;0,700;1,400;1,700&display=swap"
      rel="stylesheet"
    />
""",
        """    <!-- iGemini uses the host OS font stack; no external font request. -->
""",
    )
    system_font_stack = (
        "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, "
        "\"Helvetica Neue\", Arial, sans-serif"
    )
    replace_once(
        root / "src/index.css",
        '    font-family: "Encode Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;\n',
        f"    font-family: {system_font_stack};\n",
    )
    replace_once(
        root / "tailwind.config.js",
        """      fontFamily: {
        sans: ['"Encode Sans"', '-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', '"Helvetica Neue"', 'Arial', 'sans-serif'],
        serif: ['Merriweather', 'Georgia', 'Cambria', '"Times New Roman"', 'serif'],
      },
""",
        """      // Keep UI and chat typography native and consistent across the product.
      fontFamily: {
        sans: ['-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', '"Helvetica Neue"', 'Arial', 'sans-serif'],
        serif: ['-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', '"Helvetica Neue"', 'Arial', 'sans-serif'],
      },
""",
    )

    replace_once(
        state,
        "const DEFAULT_PROVIDER: LLMProvider = 'claude';\n",
        "const DEFAULT_PROVIDER: LLMProvider = 'claude';\n"
        "const MULTI_PROVIDER_ENABLED = import.meta.env.VITE_IGEMINI_MULTI_PROVIDER === '1';\n",
    )
    replace_once(
        state,
        "const readSelectedProvider = (): LLMProvider => {\n  try {",
        "const readSelectedProvider = (): LLMProvider => {\n"
        "  // Keep the old preference intact for a future multi-provider build, but\n"
        "  // never let it leak into a new iGemini-only session.\n"
        "  if (!MULTI_PROVIDER_ENABLED) {\n"
        "    return DEFAULT_PROVIDER;\n"
        "  }\n\n"
        "  try {",
    )

    replace_once(
        empty_state,
        "];\n\nconst MOD_KEY =",
        "];\n\n"
        "// Provider implementations stay in source for a future Codex-enabled build.\n"
        "// Public iGemini builds intentionally expose one coherent assistant.\n"
        "const MULTI_PROVIDER_ENABLED = import.meta.env.VITE_IGEMINI_MULTI_PROVIDER === \"1\";\n\n"
        "const MOD_KEY =",
    )
    replace_once(
        empty_state,
        """          <div className="mb-8 text-center">
            <h2 className="text-lg font-semibold tracking-tight text-foreground sm:text-xl">
              {t("providerSelection.title")}
            </h2>
            <p className="mt-1 text-[13px] text-muted-foreground">
              {t("providerSelection.description")}
            </p>
          </div>

          <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>""",
        """          <div className="mb-8 text-center">
            {!MULTI_PROVIDER_ENABLED && (
              <img
                src="/igemini.png"
                alt="iGemini"
                className="mx-auto mb-4 h-16 w-16 rounded-2xl shadow-sm ring-1 ring-border/50"
              />
            )}
            <h2 className="text-lg font-semibold tracking-tight text-foreground sm:text-xl">
              {MULTI_PROVIDER_ENABLED ? t("providerSelection.title") : "iGemini"}
            </h2>
            <p className="mt-1 text-[13px] text-muted-foreground">
              {MULTI_PROVIDER_ENABLED
                ? t("providerSelection.description")
                : t("providerSelection.singleProviderDescription", {
                    defaultValue: "Your AI work partner is ready for a new conversation",
                  })}
            </p>
            {!MULTI_PROVIDER_ENABLED && (
              <div className="mt-4 inline-flex items-center gap-2 rounded-full border border-border/60 bg-muted/30 px-3 py-1.5 text-xs font-medium text-foreground/80">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" />
                {t("providerSelection.singleProviderReady", {
                  defaultValue: "Ready for a new conversation",
                })}
              </div>
            )}
          </div>

          {MULTI_PROVIDER_ENABLED && <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>""",
    )
    replace_once(empty_state, "          </Dialog>\n\n          <p", "          </Dialog>}\n\n          <p")
    replace_once(
        empty_state,
        """          <p className="mt-4 text-center text-sm text-muted-foreground/70">
            {
              {
                claude: t("providerSelection.readyPrompt.claude", {
                  model: claudeModel,
                }),
                cursor: t("providerSelection.readyPrompt.cursor", {
                  model: cursorModel,
                }),
                codex: t("providerSelection.readyPrompt.codex", {
                  model: codexModel,
                }),
                opencode: t("providerSelection.readyPrompt.opencode", {
                  model: opencodeModel,
                  defaultValue: "Ready with OpenCode {{model}}",
                }),
              }[provider]
            }
          </p>""",
        """          <p className="mt-4 text-center text-sm text-muted-foreground/70">
            {MULTI_PROVIDER_ENABLED ? (
              {
                claude: t("providerSelection.readyPrompt.claude", {
                  model: claudeModel,
                }),
                cursor: t("providerSelection.readyPrompt.cursor", {
                  model: cursorModel,
                }),
                codex: t("providerSelection.readyPrompt.codex", {
                  model: codexModel,
                }),
                opencode: t("providerSelection.readyPrompt.opencode", {
                  model: opencodeModel,
                  defaultValue: "Ready with OpenCode {{model}}",
                }),
              }[provider]
            ) : t("providerSelection.singleProviderHint", {
              defaultValue: "Type below to start",
            })}
          </p>""",
    )

    replace_once(
        agents,
        "import AgentSelectorSection from './sections/AgentSelectorSection';\n",
        "import AgentSelectorSection from './sections/AgentSelectorSection';\n\n"
        "const MULTI_PROVIDER_ENABLED = import.meta.env.VITE_IGEMINI_MULTI_PROVIDER === '1';\n",
    )
    replace_once(
        agents,
        """  const visibleAgents = useMemo<AgentProvider[]>(() => {
    return ['claude', 'cursor', 'codex', 'opencode'];
  }, []);""",
        """  const visibleAgents = useMemo<AgentProvider[]>(() => {
    return MULTI_PROVIDER_ENABLED
      ? ['claude', 'cursor', 'codex', 'opencode']
      : ['claude'];
  }, []);""",
    )
    replace_once(
        agents,
        """      <AgentSelectorSection
        agents={visibleAgents}
        selectedAgent={selectedAgent}
        onSelectAgent={setSelectedAgent}
        agentContextById={agentContextById}
      />""",
        """      {MULTI_PROVIDER_ENABLED && (
        <AgentSelectorSection
          agents={visibleAgents}
          selectedAgent={selectedAgent}
          onSelectAgent={setSelectedAgent}
          agentContextById={agentContextById}
        />
      )}""",
    )

    replace_once(
        onboarding_agents,
        "import AgentConnectionCard from './AgentConnectionCard';\n",
        "import AgentConnectionCard from './AgentConnectionCard';\n\n"
        "const MULTI_PROVIDER_ENABLED = import.meta.env.VITE_IGEMINI_MULTI_PROVIDER === '1';\n",
    )
    replace_once(
        onboarding_agents,
        """}: AgentConnectionsStepProps) {
  return (
    <div className="space-y-4">""",
        """}: AgentConnectionsStepProps) {
  if (!MULTI_PROVIDER_ENABLED) {
    return (
      <div className="mx-auto max-w-md py-3 text-center">
        <img
          src="/igemini.png"
          alt="iGemini"
          className="mx-auto h-16 w-16 rounded-2xl shadow-sm ring-1 ring-border/50"
        />
        <h2 className="mt-4 font-serif text-xl font-bold tracking-tight text-foreground">
          Meet iGemini
        </h2>
        <p className="mx-auto mt-2 max-w-sm text-sm leading-relaxed text-muted-foreground">
          Your AI work partner is built in. Finish setup, then start a conversation from your workspace.
        </p>
        <div className="mx-auto mt-5 inline-flex items-center gap-2 rounded-full border border-border/60 bg-muted/30 px-3 py-1.5 text-xs font-medium text-foreground/80">
          <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" />
          One assistant, ready when you are
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-4">""",
    )

    replace_once(
        onboarding_progress,
        "import { Check, GitBranch, LogIn } from 'lucide-react';\n",
        "import { Check, GitBranch, LogIn, Sparkles } from 'lucide-react';\n\n"
        "const MULTI_PROVIDER_ENABLED = import.meta.env.VITE_IGEMINI_MULTI_PROVIDER === '1';\n",
    )
    replace_once(
        onboarding_progress,
        "  { title: 'Connect Agents', icon: LogIn, required: false },\n",
        "  MULTI_PROVIDER_ENABLED\n"
        "    ? { title: 'Connect Agents', icon: LogIn, required: false }\n"
        "    : { title: 'iGemini', icon: Sparkles, required: false },\n",
    )

    translations = {
        "en": (
            '    "description": "Select a provider to start a new conversation",\n',
            '    "description": "Select a provider to start a new conversation",\n'
            '    "singleProviderDescription": "Your AI work partner is ready for a new conversation",\n'
            '    "singleProviderReady": "Ready for a new conversation",\n'
            '    "singleProviderHint": "Type below to start",\n',
        ),
        "zh-CN": (
            '    "description": "选择一个供应商以开始新对话",\n',
            '    "description": "选择一个供应商以开始新对话",\n'
            '    "singleProviderDescription": "您的智能工作伙伴，随时开始新的对话",\n'
            '    "singleProviderReady": "可以开始新会话",\n'
            '    "singleProviderHint": "在下方输入，开始使用 iGemini",\n',
        ),
        "zh-TW": (
            '    "description": "選擇一個提供者以開始新對話",\n',
            '    "description": "選擇一個提供者以開始新對話",\n'
            '    "singleProviderDescription": "您的智慧工作夥伴，隨時開始新的對話",\n'
            '    "singleProviderReady": "可以開始新對話",\n'
            '    "singleProviderHint": "在下方輸入，開始使用 iGemini",\n',
        ),
    }
    for locale, (old, new) in translations.items():
        replace_once(root / f"src/i18n/locales/{locale}/chat.json", old, new)

    # These phrases are visible outside the provider picker. Keep them neutral
    # in both build modes so the single-assistant release does not leak an
    # implementation/provider inventory, while a future multi-provider build
    # remains semantically correct.
    neutral_copy = {
        "en": (
            "The workspace will be added to your project list and will be available for AI sessions.",
            "Learn how to use the external API to trigger AI sessions from your applications.",
        ),
        "zh-CN": (
            "工作区将被添加到您的项目列表中，并可用于 AI 会话。",
            "了解如何使用外部 API 从您的应用程序触发 AI 会话。",
        ),
        "zh-TW": (
            "工作區將加入您的專案列表，並可用於 AI 工作階段。",
            "了解如何使用外部 API 從您的應用程式觸發 AI 工作階段。",
        ),
    }
    old_common = {
        "en": "The workspace will be added to your project list and will be available for iGemini/Cursor sessions.",
        "zh-CN": "工作区将被添加到您的项目列表中，并可用于 iGemini/Cursor 会话。",
        "zh-TW": "工作區將加入您的專案列表，並可用於 iGemini/Cursor 工作階段。",
    }
    old_settings = {
        "en": "Learn how to use the external API to trigger iGemini/Cursor sessions from your applications.",
        "zh-CN": "了解如何使用外部 API 从您的应用程序触发 iGemini/Cursor 会话。",
        "zh-TW": "了解如何使用外部 API 從您的應用程式觸發 iGemini/Cursor 工作階段。",
    }
    for locale, (common_value, settings_value) in neutral_copy.items():
        common_path = root / f"src/i18n/locales/{locale}/common.json"
        for key in ("existingInfo", "newEmpty"):
            replace_once(
                common_path,
                f'      "{key}": "{old_common[locale]}",\n',
                f'      "{key}": "{common_value}",\n',
            )
        replace_once(
            root / f"src/i18n/locales/{locale}/settings.json",
            f'      "description": "{old_settings[locale]}",\n',
            f'      "description": "{settings_value}",\n',
        )

    patch_product_surface(root)

    print(
        "  CloudCLI -> iGemini single-assistant product surface; "
        "native fonts + iGemini release links; upstream promotions removed"
    )


if __name__ == "__main__":
    main()
