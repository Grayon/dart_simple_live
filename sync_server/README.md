# Simple Live Sync Server

Simple Live 数据同步中继服务，Cloudflare Worker + Durable Objects 实现，替代已停止维护的上游 SignalR 中继（`sync1.nsapps.cn`）。

- 纯 WebSocket + JSON 协议，单文件无外部依赖
- 服务端只做**临时转发**：房间状态全部保存在 Durable Object 内存/休眠态，不写数据库，不落任何业务数据
- 房间 10 分钟 TTL；创建者离开立即销毁房间
- 免费套餐即可运行（Durable Objects 需 Cloudflare 账号已绑卡验证，实际用量在免费额度内）

## 协议

WebSocket 每帧一条 JSON 文本。

连接（query 参数）：

```
/ws?room=ABCDE&role=host&app=SimpleLive&platform=android&v=1.0.0   创建房间
/ws?room=ABCDE&role=guest&app=SimpleLive&platform=ios&v=1.0.0      加入房间
```

- 房间码由**客户端生成**：5 位，字符集 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（去掉易混淆字符）。重复创建时服务端以 4003 关闭，客户端换码重试。
- `role=host` 创建房间，`role=guest` 加入。

关闭码：

| Code | 含义 |
|------|------|
| 4001 | 房间不存在（guest 加入了空房间） |
| 4002 | 房间已满（上限 16 人） |
| 4003 | 房间已存在（重复创建） |
| 4004 | 参数非法 |
| 4005 | 房间已过期 / 被创建者销毁 |

消息：

```jsonc
// S -> C
{"t":"ready","self":"A1B2","creator":true,"users":[{"id":"A1B2","app":"SimpleLive","platform":"android","version":"1.0.0","creator":true}]}
{"t":"users","users":[ ... ]}                              // 成员变化时广播
{"t":"recv","from":"C3D4","kind":"favorite","overlay":false,"content":"..."} // 收到转发
{"t":"pong"}
{"t":"destroyed"}                                          // 房间销毁前最后一条

// C -> S
{"t":"ping"}
{"t":"send","kind":"favorite","overlay":false,"content":"..."}
```

`kind` 由客户端约定（`favorite` / `history` / `shield_word` / `bili_account`），服务端原样转发，单条上限 1MB。

## 部署

```bash
npm install
npx wrangler login          # 首次需要，浏览器授权
npm run deploy
```

部署成功后拿到地址，例如 `wss://simple-live-sync.<你的账号子域>.workers.dev`，两个 App 的常量已指向线上：

- `simple_live_app/lib/services/sync_room_service.dart` → `kCloudRelayUrl`
- `simple_live_tv_app/lib/services/sync_room_service.dart` → `kCloudRelayUrl`

当前线上地址：`wss://simple-live-sync.any0host.workers.dev/ws`。值为 `wss://<域名>/ws`。重新部署到其他账号/域名后同步修改这两个常量。

绑定自定义域名：在 Cloudflare Worker 后台为该 Worker 添加 Custom Domain 即可，协议不变。

## 本地开发与测试

```bash
npm test         # 离线单测：mock WebSocket 验证 DO 全部业务逻辑（无需 npm install / workerd）
npm run dev      # 启动 workerd 本地环境，默认 127.0.0.1:8787
npm run test:e2e # 另开终端，跑真实 WebSocket 端到端用例（建房间/加入/转发/销毁/异常码）
```

端到端测试目标可传参：`node test/protocol_test.mjs http://127.0.0.1:8787`，也可指向已部署地址（用 http/https 基址，脚本自动转 ws/wss）。

## 安全说明

房间码即访问能力，不设额外鉴权，与旧版 SignalR 中继一致。不要在房间里传输敏感数据以外的内容；B 站 Cookie 同步走加密的 WSS（内网直连为局域网明文 WS，与旧版 HTTP 局域网同步相同）。
