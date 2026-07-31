---
name: sync-upstream-deploy
description: Atomically rebuild ccLoad's rw-main from the latest official upstream master, the dedicated Docker configuration branch, and explicitly listed personal or PR branches, then rebuild and verify Docker Compose. Use when asked to 一键更新上游并部署、拉取 ccLoad 上游最新提交、重建 rw-main 后部署 Docker，或更新本地源码部署。
---

# 同步上游并部署

使用内置脚本从干净上游基线整体重建 `rw-main`，构建不可变 Docker 镜像，再交给项目外、长期运行的排空发布器。不要手工复制脚本中的 Git 步骤。

## 分支职责

- `master`：官方 `upstream/master` 的干净本地镜像，不存放本地改动。
- `chore/local-docker-deployment`：持久保存 Docker 部署配置、Skill 和相关脚本。
- `dwyanewang/rw-main-branches.txt`：按顺序列出需要提前集成的个人或 PR 分支；默认为空。
- `rw-main`：从最新 `master` + 配置分支 + 清单分支每次整体重建的本地发行分支，不在此分支创建独立提交。

禁止继续把新 `master`、rebase 后的 PR 分支或配置分支追加 merge 到旧 `rw-main`；这会累积重复历史。

## 执行

1. 确认用户要求执行更新部署，而不是只询问流程。
2. 使用 `CCLOAD_DEPLOY_DIR` 指定的目录；未设置时默认为 `$HOME/Private/ccLoad`。该目录必须位于仓库外，并包含 `.env`。
3. 确认 `$CCLOAD_DEPLOY_DIR/deploy/scripts/rollout.sh` 已完成首次迁移并可执行；它负责双槽位健康检查、Nginx 切流与旧连接排空。然后在任意干净的本地分支上执行：

```bash
bash dwyanewang/sync-upstream-deploy/scripts/sync-and-deploy.sh
```

只在需要覆盖默认位置时为单次命令传入 `CCLOAD_DEPLOY_DIR=/path/to/deployment`。

4. 报告原 `master`、上游目标、候选 commit、原/新 `rw-main`、备份分支、合并的清单分支和 Compose 健康状态。

## 维护多分支清单

- 仅当用户明确要求时，向 `dwyanewang/rw-main-branches.txt` 加入个人/PR 分支；不自动发现或加入其他分支。
- 每行只写一个本地分支，可在 `#` 后记录 PR 号；合并顺序与文件顺序一致。
- 先确认源分支存在、工作区干净且改动已提交，再重建 `rw-main`。
- PR 已进入上游 `master` 后，从清单删除对应分支；上游代码由 `master` 提供，不在 `rw-main` 做 revert。

## 安全契约

脚本会执行以下保护：

- 拒绝脏工作区、detached HEAD、缺失/重复/保留分支清单项，以及已在其他 worktree 检出的目标或备份分支。
- 默认使用 `upstream=https://github.com/caidaoli/ccLoad.git`；仅在远程不存在时添加，不覆盖已有远程。
- 要求当前 `master` 可 fast-forward 到上游目标，不修改配置分支历史。
- 从上游目标创建临时候选分支，依次 `--no-ff` 合并配置分支和清单分支。
- 在候选分支上完成 Compose 配置验证和镜像构建；任一步失败时删除候选，`master` 和旧 `rw-main` 保持不变。
- 验证通过后，将旧 `rw-main` 保存为 `rw-main-backup-latest`，再原子更新 `master` 和 `rw-main`。
- 永不执行 stash、hard reset、rebase、force push 或普通 push。
- 成功后停留在 `rw-main`，将不可变镜像标签交给项目外的发布器；发布器健康检查新槽位、切换入口代理并排空旧槽位。
- 发布成功并再次确认活动 Compose 槽位健康后，只保留当前 `rw-main` 与 `rw-main-backup-latest` 对应的 `ccload:rw-*` 镜像；更早的发布镜像使用非强制删除，删除失败只告警。
- 不自动执行全局 BuildKit cache prune；默认构建器可能由多个项目共享，缓存容量治理必须作为独立、显式的主机维护操作。

`--dry-run` 会 fetch 上游、创建和验证临时候选，但不移动 `master`/`rw-main` 且不启动服务。用户明确要求更新部署时直接执行正常模式。

## 可选覆盖

- `CCLOAD_UPSTREAM_REMOTE`：默认 `upstream`
- `CCLOAD_UPSTREAM_URL`：默认官方 GitHub 仓库
- `CCLOAD_UPSTREAM_BRANCH`：默认 `master`
- `CCLOAD_COMPOSE_FILE`：默认 `docker-compose.build.yml`
- `CCLOAD_DEPLOY_WAIT_TIMEOUT`：默认 180 秒

任何预检、fetch、候选合并、Compose 验证、镜像构建或健康检查失败时，停止并报告准确错误；不要自动扩大修复范围。
