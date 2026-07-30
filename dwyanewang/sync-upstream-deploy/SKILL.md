---
name: sync-upstream-deploy
description: Safely synchronize ccLoad's local master with the latest official upstream commit, update the dedicated deployment-configuration branch, fast-forward rw-main, and rebuild and verify Docker Compose. Use when asked to 一键更新上游并部署、拉取 ccLoad 上游最新提交、更新 rw-main 后重建 Docker，或更新本地源码部署。
---

# 同步上游并部署

使用内置脚本完成 Git 同步、配置分支更新、`rw-main` 快进、Docker 重建和健康验证。不要手工复制脚本中的 Git 步骤。

## 分支职责

- `master`：只快进到官方 `upstream/master`，不存放本地部署改动。
- `chore/local-docker-deployment`：唯一的本地部署配置与 Skill 维护分支。
- `rw-main`：实际 Docker 构建和运行分支；只允许快进到配置分支，不在此分支创建独立提交。

## 执行

1. 确认用户要求执行更新部署，而不是只询问流程。
2. 从当前 shell 或用户提供的值取得 `CCLOAD_DEPLOY_DIR`。该目录必须位于仓库外，并包含 `.env`；不要猜测未提供的路径。
3. 在任意干净的本地分支上直接执行：

```bash
CCLOAD_DEPLOY_DIR=/path/to/deployment \
  bash dwyanewang/sync-upstream-deploy/scripts/sync-and-deploy.sh
```

4. 报告原 `master` commit、上游目标 commit、配置分支 commit、`rw-main` commit 和 Compose 健康状态。

## 安全契约

脚本会执行以下保护：

- 拒绝带有已跟踪或未跟踪改动的工作区。
- 默认使用 `upstream=https://github.com/caidaoli/ccLoad.git`；仅在远程不存在时添加，不覆盖已有远程。
- 只允许 `master` fast-forward，再将 `master` 合并到 `chore/local-docker-deployment`。
- 只允许 `rw-main` fast-forward 到 `chore/local-docker-deployment`；如果 `rw-main` 有独立提交则拒绝执行。
- 合并冲突时自动 abort 并返回调用前分支。
- 永不执行 stash、hard reset、rebase、force push 或普通 push。
- 成功后停留在 `rw-main`，先验证 Compose 配置，再执行 `up -d --build --wait`。

可用 `--dry-run` 只显示将要执行的流程。只有用户要求预览时才使用它；用户明确要求更新部署时直接执行正常模式。

## 可选覆盖

- `CCLOAD_UPSTREAM_REMOTE`：默认 `upstream`
- `CCLOAD_UPSTREAM_URL`：默认官方 GitHub 仓库
- `CCLOAD_UPSTREAM_BRANCH`：默认 `master`
- `CCLOAD_COMPOSE_FILE`：默认 `docker-compose.build.yml`
- `CCLOAD_DEPLOY_WAIT_TIMEOUT`：默认 180 秒

任何预检、fetch、fast-forward、merge、Compose 验证或健康检查失败时，停止并报告准确错误；不要自动扩大修复范围。
