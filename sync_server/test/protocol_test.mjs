// 协议端到端测试：对运行中的 Worker（wrangler dev 或已部署地址）执行全部流程。
// 用法：node test/protocol_test.mjs [http_base]
const BASE = (process.argv[2] || "http://127.0.0.1:8787").replace(/\/$/, "");
const WS_BASE = BASE.replace(/^http/, "ws");

let passed = 0;
const failures = [];
function check(name, cond, detail = "") {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failures.push(`${name} ${detail}`);
    console.error(`  ✗ ${name} ${detail}`);
  }
}

const ROOM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const randomRoom = () =>
  Array.from(
    { length: 5 },
    () => ROOM_ALPHABET[Math.floor(Math.random() * ROOM_ALPHABET.length)]
  ).join("");

function connect(room, role, { app = "SimpleLive", platform = "android", v = "1.0.0" } = {}) {
  const url = `${WS_BASE}/ws?room=${room}&role=${role}&app=${encodeURIComponent(
    app
  )}&platform=${platform}&v=${v}`;
  const ws = new WebSocket(url);
  const events = [];
  const onMsg = (m) => events.push(JSON.parse(m.data));
  ws.addEventListener("message", onMsg);
  return {
    ws,
    events,
    open: new Promise((res, rej) => {
      ws.addEventListener("open", res, { once: true });
      ws.addEventListener("error", (e) => rej(new Error("ws error")), {
        once: true,
      });
    }),
    closed: new Promise((res) =>
      ws.addEventListener("close", (e) => res({ code: e.code, reason: e.reason }))
    ),
    waitFor: async (pred, timeoutMs = 5000) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const hit = events.find(pred);
        if (hit) return hit;
        await new Promise((r) => setTimeout(r, 30));
      }
      throw new Error(`timeout waiting for message; got ${JSON.stringify(events)}`);
    },
    send: (obj) => ws.send(JSON.stringify(obj)),
  };
}

async function main() {
  console.log("== HTTP ==");
  const health = await fetch(`${BASE}/healthz`);
  check("GET /healthz 200", health.status === 200);
  const badRoom = await fetch(
    `${WS_BASE.replace(/^ws/, "http")}/ws?room=ab!&role=host&app=a&platform=p`
  );
  check("非法房间码 400", badRoom.status === 400);

  console.log("== 房间生命周期 ==");
  const room = randomRoom();
  const host = connect(room, "host", { platform: "macos" });
  await host.open;
  const ready = await host.waitFor((m) => m.t === "ready");
  check("host 收到 ready", ready.creator === true && ready.users.length === 1);
  const hostId = ready.self;

  console.log("== 访客加入 ==");
  const guest = connect(room, "guest", { platform: "ios" });
  await guest.open;
  const gReady = await guest.waitFor((m) => m.t === "ready");
  check("guest 收到 ready", gReady.creator === false && gReady.users.length === 2);
  check(
    "host 收到 users 更新",
    !!(await host.waitFor((m) => m.t === "users" && m.users.length === 2))
  );
  check(
    "用户列表含创建者标记",
    gReady.users.some((u) => u.id === hostId && u.creator === true)
  );

  console.log("== 消息转发 ==");
  host.events.length = 0;
  guest.send({
    t: "send",
    kind: "favorite",
    overlay: false,
    content: '[{"id":1}]',
  });
  const recv = await host.waitFor((m) => m.t === "recv");
  check("host 收到转发", recv.kind === "favorite" && recv.content === '[{"id":1}]');
  check("转发方标记 from", recv.from === gReady.self);
  check("发送者收不到自己的消息", !guest.events.some((m) => m.t === "recv"));

  console.log("== ping ==");
  host.send({ t: "ping" });
  check("pong", !!(await host.waitFor((m) => m.t === "pong")));

  console.log("== 异常分支 ==");
  const host2 = connect(room, "host");
  const close2 = await host2.closed;
  check("重复创建被拒 4003", close2.code === 4003, `got ${close2.code}`);

  const ghost = connect(randomRoom(), "guest");
  const closeGhost = await ghost.closed;
  check("加入空房间被拒 4001", closeGhost.code === 4001, `got ${closeGhost.code}`);

  // 非法消息被忽略而非断开
  guest.send("not-json");
  guest.send(JSON.stringify({ t: "send", kind: 123, content: "x" }));
  await new Promise((r) => setTimeout(r, 500));
  check("非法消息不影响连接", guest.ws.readyState === WebSocket.OPEN);

  console.log("== 创建者离开销毁房间 ==");
  host.ws.close();
  const destroyed = await guest.waitFor((m) => m.t === "destroyed");
  check("guest 收到 destroyed", !!destroyed);
  const gClose = await guest.closed;
  check("guest 被断开", gClose.code === 4005, `got ${gClose.code}`);

  console.log(`\n${passed} passed, ${failures.length} failed`);
  if (failures.length) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
