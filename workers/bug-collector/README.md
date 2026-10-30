# KVJ 错误收集

生产入口：<https://bug.kvj.kumo.ltd>（Worker `kvj-bug-collector`，2026-10-26 起以 503 占位）。Workers 接收用户主动提交的报告，D1 保存报告；首页是管理员查看面板，报告列表、详情和删除接口均要求管理员密钥。代码与 KDJ 的 `workers/bug-collector` 相同，报告格式（schema 1）也相同。

## 用户侧

顶栏「关于」→「将错误上报至开发者」：先生成并核对完整脱敏预览，勾选本次同意，再点击确认上传。预览保留 15 分钟，发送的是同一份冻结内容，不会在上传时偷偷追加新日志。不会自动上传、自动重试，也不会记住下次同意；网络失败可手动重试同一报告，服务端按随机报告 ID 去重。

报告内容：最近两天会话日志（`<数据目录>/logs/kvj-*.log`）的最后约 384 KiB、最多 300 条，以及引擎记录的 panic（`logs/panics.log`），每条逐行脱敏；附软件版本、系统、架构、CPU 线程数和用户填写的描述。报告最多 256 KiB，超出时舍弃较早条目并注明数量。

## 隐私与保留

只发送报告预览中的内容。不附加素材、Set 文件、截图或设置。对常见凭证、用户路径（因此素材文件名随路径一并隐藏）、URL、邮箱、IP、手机号和长标识做自动脱敏，服务端再脱敏一次。自由文本无法保证识别所有私人内容，上传前必须人工核对。

应用只在用户确认上传时访问收集器。Cloudflare 作为网络处理方必然接触来源 IP；数据库不保存 IP、User-Agent 或身份标识，来源 IP 仅用于边缘临时限流。报告接收满 30 天后不再可查询，每日定时清理。单 IP 每分钟 5 次，单节点全局每分钟 100 次；数据库最多 1000 份、滚动 24 小时 100 份新报告，超限返回 429。

## 管理与部署

在 Mac 上用已登录的 Wrangler 执行（不要把 Cloudflare 凭证写进文件或仓库）：

```sh
cd workers/bug-collector
npm ci --ignore-scripts
npx wrangler d1 create kvj-bug-reports      # 把返回的 database_id 填进 wrangler.jsonc
npm run check
npx wrangler d1 migrations apply kvj-bug-reports --remote
npm run deploy                               # 替换 503 占位版本
npx wrangler secret put ADMIN_TOKEN
```

`ADMIN_TOKEN` 是独立的随机管理密钥，不是 Cloudflare API Token，绝不放进应用或仓库；本机副本放 `~/.config/kvj-bug-collector/admin-token`（目录 0700，文件 0600）。面板登录后只在内存持有它。
