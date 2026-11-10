// test/control-election.test.mjs —— v1.0.1 多浏览器受控权互斥（服务端选举）
//
// 规则：所有连接在 ext/hello.control 里报 {enabled, claimTs, label}；
//   - 只有 controlEnabled 的连接参与选举，claimTs 最大者胜（并列取最近注册）；
//   - liveConnections() 把受控实例排第一（= 默认浏览器，互斥）；
//   - 选举结果通过 onControlState 广播给所有连接；
//   - 受控实例断开 → 立刻把受控权交给还在线的另一个。
//
// 用真实 WS 连接模拟两个浏览器（无 Origin → 走 host 兼容路径，不需要 token）。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import net from 'node:net';
import { ConnectionManager } from '../service/connection.mjs';
import { EV } from '../shared/protocol.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((res) => {
  const s = new net.Server();
  s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); });
});

function openClient(port) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/`);
    const state = { ws, frames: [] };
    ws.on('message', (d) => { try { state.frames.push(JSON.parse(String(d))); } catch { /* 忽略坏帧 */ } });
    ws.on('open', () => resolve(state));
    ws.on('error', reject);
  });
}

const hello = (c, instanceId, { enabled = true, claimTs = 0, label = instanceId } = {}) => {
  c.ws.send(JSON.stringify({
    jsonrpc: '2.0', method: EV.HELLO,
    params: { instanceId, family: 'chrome', browserVersion: '157', control: { enabled, claimTs, label } },
  }));
};

const controlStates = (c) => c.frames.filter((f) => f.method === EV.CONTROL_STATE).map((f) => f.params);
const lastState = (c) => { const s = controlStates(c); return s[s.length - 1]; };

test('互斥选举：claimTs 大的胜出；断开后自动转移；liveConnections 受控在前', async () => {
  const port = await freePort();
  const manager = new ConnectionManager({ port });
  await manager.start();
  const A = await openClient(port);
  const B = await openClient(port);
  try {
    // A 先要受控（claim 1000）
    hello(A, 'inst-A', { claimTs: 1000, label: 'chrome A' });
    await sleep(250);
    assert.equal(manager.activeInstanceId, 'inst-A', 'A 应为当前受控');
    assert.equal(manager.liveConnections()[0].instanceId, 'inst-A', '受控实例排在 liveConnections 第一位（默认浏览器）');
    assert.equal(lastState(A).activeInstanceId, 'inst-A', 'A 收到受控广播');

    // B 以更新的 claim 抢占 → A 变待机，B 受控
    hello(B, 'inst-B', { claimTs: 2000, label: 'chrome B' });
    await sleep(250);
    assert.equal(manager.activeInstanceId, 'inst-B', 'B 应抢到受控权');
    assert.equal(manager.liveConnections()[0].instanceId, 'inst-B', '默认浏览器跟随受控权');
    assert.equal(lastState(A).activeInstanceId, 'inst-B', 'A 收到“你已待机”广播');
    assert.equal(lastState(B).activeInstanceId, 'inst-B');

    // 旧 claim 不能反抢（防抖/乱序）
    hello(A, 'inst-A', { claimTs: 500, label: 'chrome A' });
    await sleep(250);
    assert.equal(manager.activeInstanceId, 'inst-B', '较旧 claimTs 不应抢回受控权');

    // 关闭控制开关 → 退出选举；B 仍是受控
    hello(A, 'inst-A', { enabled: false, claimTs: 500, label: 'chrome A' });
    await sleep(200);
    assert.equal(manager.activeInstanceId, 'inst-B');

    // B 断开 → 受控权不应给已关闭的 A（A enabled=false），应为无人
    B.ws.close();
    await sleep(300);
    assert.equal(manager.activeInstanceId, null, 'B 断开且 A 已关闭 → 无人受控');
    assert.equal(manager.liveConnections().length, 1, 'A 仍在连但不受控');
  } finally {
    try { A.ws.close(); } catch { /* noop */ }
    await manager.stop();
  }
});
