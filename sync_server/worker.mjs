/**
 * Simple Live 数据同步中继 —— Cloudflare Worker + Durable Object（房间模式）
 *
 * 协议：WebSocket，每帧一条 JSON 文本消息
 *
 * 连接（URL query）：
 *   /ws?room=ABCDE&role=host&app=SimpleLive&platform=android&v=1.0.0   创建房间
 *   /ws?room=ABCDE&role=guest&app=SimpleLive&platform=ios&v=1.0.0      加入房间
 *
 * 关闭码：
 *   4001 房间不存在（guest 加入了空房间）
 *   4002 房间已满
 *   4003 房间已存在（重复创建）
 *   4004 参数非法
 *   4005 房间已过期
 *
 * 服务端 -> 客户端：
 *   {"t":"ready","self":"a1b2","room":"ABCDE","creator":true,"users":[...]}
 *   {"t":"users","users":[{"id":"a1b2","app":"..","platform":"..","version":"..","creator":true}]}
 *   {"t":"recv","from":"c3d4","kind":"favorite","overlay":false,"content":"..."}
 *   {"t":"pong"}
 *   {"t":"destroyed"}                         创建者离开或房间超时
 *
 * 客户端 -> 服务端：
 *   {"t":"ping"}
 *   {"t":"send","kind":"favorite","overlay":false,"content":"..."}
 *
 * 服务端只做临时转发，不持久化任何业务数据。
 */

const ROOM_CODE_RE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}$/;
const MAX_MEMBERS = 16;
const ROOM_TTL_MS = 10 * 60 * 1000; // 与客户端 10 分钟倒计时一致
const MAX_CONTENT_LEN = 1024 * 1024; // 单条消息 1MB
const TAG_LEN = 40;

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export default {
  /**
   * @param {Request} request
   * @param {{ ROOMS: DurableObjectNamespace }} env
   */
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/" ) {
      return new Response(
        `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Simple Live Sync</title></head>
<body><h1>Simple Live Sync</h1><p>数据同步中继服务运行中</p></body></html>`,
        { headers: { "Content-Type": "text/html; charset=utf-8" } }
      );
    }
    if (url.pathname === "/healthz") {
      return new Response("ok", { headers: { "Content-Type": "text/plain" } });
    }
    if (url.pathname !== "/ws") {
      return new Response("not found", { status: 404 });
    }

    const room = (url.searchParams.get("room") || "").toUpperCase();
    const role = url.searchParams.get("role");
    if (!ROOM_CODE_RE.test(room)) {
      return Response.json(
        { error: "invalid room code" },
        { status: 400 }
      );
    }
    if (role !== "host" && role !== "guest") {
      return Response.json({ error: "invalid role" }, { status: 400 });
    }
    const app = (url.searchParams.get("app") || "").slice(0, TAG_LEN);
    const platform = (url.searchParams.get("platform") || "").slice(
      0,
      TAG_LEN
    );
    const version = (url.searchParams.get("v") || "").slice(0, TAG_LEN);
    if (!app || !platform) {
      return Response.json({ error: "missing identity" }, { status: 400 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return Response.json(
        { error: "websocket upgrade required" },
        { status: 426 }
      );
    }

    // 房间码即 DO 名称：客户端负责生成，撞码（重复创建）时客户端换码重试。
    // 直接转发原始 Request（保留 Upgrade 头），身份信息走 query。
    const id = env.ROOMS.idFromName(room);
    return env.ROOMS.get(id).fetch(request);
  },
};

export class RoomDO {
  /** @param {DurableObjectState} state */
  constructor(state) {
    this.state = state;
  }

  _att(ws) {
    if (typeof this.state.getAttachment === "function") {
      return this.state.getAttachment(ws);
    }
    // 旧版 workerd：附件挂在 WebSocket 上
    if (typeof ws.deserializeAttachment === "function") {
      return ws.deserializeAttachment();
    }
    return typeof ws.attachment === "function" ? ws.attachment() : ws.attachment;
  }

  /** @param {Request} request */
  async fetch(request) {
    try {
      return await this._handle(request);
    } catch (e) {
      console.error("RoomDO error", e);
      return new Response("internal error", { status: 500 });
    }
  }

  async _handle(request) {
    const url = new URL(request.url);
    const role = url.searchParams.get("role");
    const app = (url.searchParams.get("app") || "").slice(0, TAG_LEN);
    const platform = (url.searchParams.get("platform") || "").slice(
      0,
      TAG_LEN
    );
    const version = (url.searchParams.get("v") || "").slice(0, TAG_LEN);

    const pair = new WebSocketPair();
    const client = pair[0];
    const peer = pair[1];

    const members = this.state.getWebSockets();
    const host = members.find(
      (s) => (this.state.getTags(s) || [])[0] === "role:host"
    );

    // 拒绝连接：workerd 不允许在未 accept 的 socket 上 close，
    // 先 accept（标记 reject，不进成员列表）再立即带码关闭。
    const reject = (code, reason) => {
      this.state.acceptWebSocket(client, ["reject"]);
      client.close(code, reason);
      return new Response(null, { status: 101, webSocket: peer });
    };

    if (role === "host" && host) {
      return reject(4003, "room already exists");
    }
    if (role === "guest" && !host) {
      return reject(4001, "room not found");
    }
    const activeCount = members.filter(
      (s) => (this.state.getTags(s) || [])[0] !== "reject"
    ).length;
    if (activeCount >= MAX_MEMBERS) {
      return reject(4002, "room is full");
    }

    const selfId = randomId();
    // tags 只能是字符串数组，角色放 tags[0]；其余身份信息走 attachment
    this.state.acceptWebSocket(client, [`role:${role}`]);
    const attachment = {
      id: selfId,
      app,
      platform,
      version,
      creator: role === "host",
    };
    // 兼容不同 workerd 版本：新版在 state 上，旧版在 WebSocket 上
    if (typeof this.state.serializeAttachment === "function") {
      this.state.serializeAttachment(client, attachment);
    } else {
      client.serializeAttachment(attachment);
    }

    const users = this.listUsers();
    client.send(
      JSON.stringify({
        t: "ready",
        self: selfId,
        creator: role === "host",
        users,
      })
    );
    this.broadcastUsers();
    this.state.storage.setAlarm(Date.now() + ROOM_TTL_MS);

    return new Response(null, { status: 101, webSocket: peer });
  }

  /**
   * @param {WebSocket} ws
   * @param {string | ArrayBuffer} message
   */
  async webSocketMessage(ws, message) {
    const att = this._att(ws);
    if (!att || typeof message !== "string") return;

    let msg;
    try {
      msg = JSON.parse(message);
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object") return;

    if (msg.t === "ping") {
      ws.send(JSON.stringify({ t: "pong" }));
      return;
    }

    if (msg.t !== "send") return;
    const kind = msg.kind;
    const content = msg.content;
    if (
      typeof kind !== "string" ||
      kind.length > 40 ||
      typeof content !== "string" ||
      content.length > MAX_CONTENT_LEN
    ) {
      return;
    }
    const overlay = msg.overlay === true;
    const payload = JSON.stringify({
      t: "recv",
      from: att.id,
      kind,
      overlay,
      content,
    });
    for (const other of this._activeSockets()) {
      if (other !== ws) {
        try {
          other.send(payload);
        } catch {
          // 休眠连接异常时忽略，close 事件会清理
        }
      }
    }
  }

  /** @param {WebSocket} ws */
  webSocketClose(ws) {
    const tags = this.state.getTags(ws) || [];
    if (tags[0] === "role:host") {
      // 创建者离开：销毁房间，踢掉所有人
      const guests = this.state
        .getWebSockets()
        .filter((s) => s !== ws);
      for (const guest of guests) {
        try {
          guest.send(JSON.stringify({ t: "destroyed" }));
          guest.close(4005, "room destroyed");
        } catch {}
      }
      this.state.storage.deleteAlarm();
      return;
    }
    this.broadcastUsers();
  }

  webSocketError(ws) {
    // 错误随后会触发 close，统一在 close 里处理
  }

  async alarm() {
    // 房间 TTL 到期
    for (const sock of this.state.getWebSockets()) {
      try {
        sock.send(JSON.stringify({ t: "destroyed" }));
        sock.close(4005, "room expired");
      } catch {}
    }
  }

  /** 房间内有效成员（排除被拒绝后尚未清理的连接） */
  _activeSockets() {
    return this.state
      .getWebSockets()
      .filter((s) => (this.state.getTags(s) || [])[0] !== "reject");
  }

  listUsers() {
    return this._activeSockets().map((s) => {
      const att = this._att(s);
      return {
        id: att ? att.id : "----",
        app: att ? att.app : "",
        platform: att ? att.platform : "",
        version: att ? att.version : "",
        creator: att ? att.creator : false,
      };
    });
  }

  broadcastUsers() {
    const sockets = this._activeSockets();
    if (sockets.length === 0) {
      return;
    }
    const payload = JSON.stringify({ t: "users", users: this.listUsers() });
    for (const sock of sockets) {
      try {
        sock.send(payload);
      } catch {}
    }
  }
}

function randomId() {
  let out = "";
  for (let i = 0; i < 4; i++) {
    out += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  return out;
}
