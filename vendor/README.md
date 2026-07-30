# vendor/

本仓库不把 CloudCLI 源码做成 submodule，也不维护长期 fork。各平台构建脚本从官方仓库拉取固定 commit，再应用本目录中的共享白标 patch。

## iGemini 白标 patch

`igemini-claudecodeui.patch` 记录跨平台共享的品牌改动：logo、favicon/PWA 图标、界面与服务端可见品牌文字、i18n 文案及 Claude provider 的 iGemini 显示名。运行时隔离、权限模式、Shell、JWT、限流和改密属于平台补丁，不混入这份共享 patch。

- 上游版本：CloudCLI `v1.36.3`
- 上游 tag 解引用 commit：`27eaf0146a46aa8a55178f3d394360ff7465420f`
- patch 文件数：94（含二进制图标）
- 不含构建产物、依赖或密钥

## 复现

```bash
git clone https://github.com/siteboon/claudecodeui
cd claudecodeui
git checkout 27eaf0146a46aa8a55178f3d394360ff7465420f
git apply --check --binary ../igemini-claudecodeui.patch
git apply --binary ../igemini-claudecodeui.patch
npm ci
npm run typecheck
npm run build
```

必须使用上述 commit；上游分支继续前移后，直接在最新 `main` 上应用不保证成功。若升级到新的 CloudCLI 版本，应对新 tag 逐项重放白标改动，执行品牌残留审计和完整构建，再重新生成 patch：

```bash
git add -A
git diff --cached --binary > igemini-claudecodeui.patch
git reset
```

平台运行时补丁位于 `scripts/common/` 和各 OS 构建脚本中，不属于这份共享白标 patch。

CloudCLI 及本衍生 patch 受 AGPL-3.0 约束；完整归属与对应源码说明见仓库根目录的 `NOTICE` 和 `LICENSE`。
