# 贡献与分支规定

## 分支

- `main` 是唯一的长期分支。所有发布标签 (`vX.Y.Z`) 都打在 main 上 (`git merge-base --is-ancestor vX.Y.Z origin/main` 必须成立)。
- 分支命名: `feat/<简述>`、`fix/<简述>`、`chore/<简述>`、`website/<简述>`; 发布 PR 用 `release/<版本>`。
- 自动化工具生成的分支 (`codex/*`、`claude/*`) 同样遵守本规定。
- 合并后立即删除分支 (远端和本地都删)。不保留"已合并"的分支。
- 只允许两类未合并分支存在: 有打开的 PR, 或在 PR 里写明了保留原因的工作。

## 合并

- 所有改动通过 PR 合入 `main`, 不直接推送 `main`。
- squash 合并后, `git branch --merged` 不会把分支显示为已合并。清理前用 `gh pr list --state all --head <分支>` 查 PR 状态, 再删分支。
- 删除命令: `git push origin --delete <分支>`; 本地 `git branch -D <分支>` (squash 之后 `-d` 会拒绝)。

## 发布

- 版本号写在 `VERSION`, 变更写在 `CHANGELOG.md`。
- 发布 PR 用 `release/<版本>` 分支, 合并进 `main` 后删除该分支, 然后在 `main` 上打 `v<版本>` 标签。
