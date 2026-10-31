// Durable Object 业务逻辑离线单元测试（无需 workerd / npm install）：
// 用内存 FakeWebSocket 模拟 Hibernation API，直接驱动 RoomDO 和外层 Worker.fetch。
// 完整 WebSocket 端到端用 test/protocol_test.mjs（需 wrangler dev）。
import assert from "node:assert";

// ---- workerd API mocks ----
globalThis.WebSocketPair = class {
  constructor() {
    const state = { closed: null, sent: [] };
    // 真实 workerd 中关闭一端会反映到对端，mock 里让两端共享状态
    const make = (label) => ({
      label,
      get sent() {
        return state.sent;
      },
      get closed() {
        return state.closed;
      },
      send(m) {
        if (state.closed) throw new Error("send after close");
        state.sent.push(m);
      },
      close(code, reason) {
        state.closed = { code, reason };
      },
      lastJson() {
        return JSON.parse(state.sent[state.sent.length - 1]);
      },
    });
    this[0] = make("client");
    this[1] = make("peer");
  }
};

// Node 的 Response 不接受 101，包一层把 webSocket 挂到 200 响应上
const NativeResponse = globalThis.Response;
globalThis.Response = class extends NativeResponse {
  constructor(body, init) {
    if (init && init.status === 101) {
      super(body, { ...init, status: 200 });
      this.webSocket = init.webSocket;
    } else {
      super(body, init);
    }
  }
  static json(...a) {
    return NativeResponse.json(...a);
  }
};

class FakeState {
  constructor() {
    this.conns = new Map();
    this.attachments = new Map();
    this.alarmAt = null;
  }
  acceptWebSocket(ws, tags) {
    this.conns.set(ws, { tags });
  }
  rejectTag() {
    return "reject";
  }
  getWebSockets() {
    return [...this.conns.keys()].filter((ws) => !ws.closed);
  }
  getTags(ws) {
    return this.conns.get(ws)?.tags;
  }
  serializeAttachment(ws, att) {
    this.attachments.set(ws, att);
  }
  getAttachment(ws) {
    return this.attachments.get(ws);
  }
  storage = {
    setAlarm: async (t) => {
      this.alarmAt = t;
    },
    deleteAlarm: async () => {
      this.alarmAt = null;
    },
  };
}

const { default: worker, RoomDO } = await import("../worker.mjs");

let n = 0;
const ok = (name) => console.log(`  ✓ ${++n}. ${name}`);

function envFor(doInstance) {
  return {
    ROOMS: {
      idFromName: (r) => r,
      get: () => ({ fetch: (req) => doInstance.fetch(req) }),
    },
  };
}

const wsReq = (url) =>
  new Request(url, { headers: { Upgrade: "websocket" } });

async function main() {
  console.log("== 外层 Worker 校验 ==");
  let r = await worker.fetch(wsReq("https://x/ws?room=AB!&role=host&app=a&platform=p"), {});
  assert.equal(r.status, 400);
  ok("非法房间码 400");

  r = await worker.fetch(wsReq("https://x/ws?room=ABCDE&role=x&app=a&platform=p"), {});
  assert.equal(r.status, 400);
  ok("非法 role 400");

  r = await worker.fetch(wsReq("https://x/ws?room=ABCDE&role=host"), {});
  assert.equal(r.status, 400);
  ok("缺少身份参数 400");

  r = await worker.fetch(
    new Request("https://x/ws?room=ABCDE&role=host&app=a&platform=p")
  );
  assert.equal(r.status, 426);
  ok("非 Upgrade 请求 426");

  r = await worker.fetch(new Request("https://x/healthz"));
  assert.equal(r.status, 200);
  ok("健康检查 200");

  console.log("== 房间生命周期 ==");
  const state = new FakeState();
  const room = new RoomDO(state);
  const env = envFor(room);
  const ROOM = "https://x/ws?room=NK7QH&app=SimpleLive&platform=tv&v=1.0.0";

  async function join(role) {
    const resp = await worker.fetch(wsReq(ROOM + `&role=${role}`), env);
    const peer = resp.webSocket;
    const client = state.conns.has(peer)
      ? peer
      : [...state.conns.keys()].find(
          (c) => !c.closed && (state.getTags(c) || [])[0] === `role:${role}`
        );
    return { resp, client, peer };
  }

  const host = await join("host");
  const ready = JSON.parse(host.client.sent[0]);
  assert.equal(ready.t, "ready");
  assert.equal(ready.creator, true);
  assert.equal(ready.users.length, 1);
  assert.equal(ready.self.length, 4);
  ok("host 收到 ready 且为创建者");

  // 重复创建：peer 被 close 4003
  const dup = await join("host");
  assert.equal(dup.peer.closed?.code, 4003);
  ok("重复创建被拒 4003");

  console.log("== guest 加入 ==");
  const g1 = await join("guest");
  const gReady = JSON.parse(g1.client.sent[0]);
  assert.equal(gReady.t, "ready");
  assert.equal(gReady.creator, false);
  assert.equal(gReady.users.length, 2);
  // host 也收到 users 广播
  const hostUsers = JSON.parse(host.client.sent.at(-1));
  assert.equal(hostUsers.t, "users");
  assert.equal(hostUsers.users.length, 2);
  ok("加入后双方 users 列表更新");

  console.log("== 消息转发 ==");
  await room.webSocketMessage(
    g1.client,
    JSON.stringify({ t: "send", kind: "favorite", overlay: true, content: '[{"id":1}]' })
  );
  const relayed = host.client.lastJson();
  assert.equal(relayed.t, "recv");
  assert.equal(relayed.kind, "favorite");
  assert.equal(relayed.overlay, true);
  assert.equal(relayed.content, '[{"id":1}]');
  assert.equal(relayed.from, state.getAttachment(g1.client).id);
  ok("host 收到 guest 转发且带 from/overlay");
  assert.ok(!g1.client.sent.some((m) => JSON.parse(m).t === "recv"));
  ok("发送者收不到自己的消息");

  console.log("== ping/异常消息 ==");
  await room.webSocketMessage(host.client, JSON.stringify({ t: "ping" }));
  assert.equal(host.client.lastJson().t, "pong");
  ok("ping 返回 pong");
  await room.webSocketMessage(host.client, "not-json");
  await room.webSocketMessage(host.client, JSON.stringify({ t: "send", kind: 123 }));
  await room.webSocketMessage(host.client, JSON.stringify({ t: "unknown" }));
  assert.ok(!host.client.closed);
  ok("非法/未知消息被忽略且不断开");

  console.log("== 空房间 guest ==");
  const empty = new RoomDO(new FakeState());
  const env2 = envFor(empty);
  const ghost = await worker.fetch(wsReq(ROOM + "&role=guest"), env2);
  assert.equal(ghost.webSocket.closed?.code, 4001);
  ok("加入空房间被拒 4001");

  console.log("== host 离开销毁房间 ==");
  await room.webSocketClose(host.client);
  const destroyed = g1.client.sent.map(JSON.parse).find((m) => m.t === "destroyed");
  assert.ok(destroyed);
  assert.equal(g1.client.closed?.code, 4005);
  ok("guest 收到 destroyed 并被 4005 断开");

  console.log(`\n${n} checks passed`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
