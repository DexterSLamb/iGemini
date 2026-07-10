# vendor/

## `igemini-claudecodeui.patch`

A single git patch that white-labels **claudecodeui** (product name *CloudCLI*,
by [siteboon](https://github.com/siteboon/claudecodeui), AGPL-3.0) into
**iGemini**: logo / favicon / manifest icons, brand strings, i18n, and the
provider display name.

This repository does **not** vendor claudecodeui's source — only this diff
against a pinned upstream commit. The build scripts (`scripts/<os>/…`) fetch
the upstream at that commit and apply the patch; the patch is **only applied,
never forked**.

**Apply / reproduce:**

```sh
git clone https://github.com/siteboon/claudecodeui
cd claudecodeui
git checkout 4712431be81718dfb559ef43d7d7d5315bf4e01a
git apply --binary ../igemini-claudecodeui.patch
```

Because it is a derivative of an AGPL-3.0 work, this patch is itself covered
by AGPL-3.0. See the repository-root `NOTICE` for full attribution and the
corresponding-source statement.

> Each OS additionally applies a small platform-specific factory tweak that is
> **not** part of this shared patch (see the per-OS build scripts and `NOTICE`).
