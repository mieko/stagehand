import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { get } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { connect } from '../client.mjs';
import { launchFixture } from './fixture.mjs';

test('the client derives the RPC address from the HTTP or HTTPS base', async () => {
  const seen = [];
  const intercepted = new Error('intercepted WebSocket construction');
  class Socket {
    constructor(url) {
      seen.push(url);
      throw intercepted;
    }
  }

  for (const address of ['http://[::1]:1234/', new URL('https://game.example')]) {
    await assert.rejects(connect(address, { WebSocket: Socket }), error => error === intercepted);
  }
  assert.deepEqual(seen, ['ws://[::1]:1234/rpc', 'wss://game.example/rpc']);
  await assert.rejects(connect('ftp://game.example'), /http:\/\/ or https:\/\//);
});

test('a running game serves its client and separate API references', async (t) => {
  const fixture = await launchFixture({ fixture: 'transport' });
  t.after(fixture.stop);
  const base = fixture.url;
  const local = await mkdtemp(join(tmpdir(), 'stagehand-download-'));
  t.after(() => rm(local, { recursive: true, force: true }));

  const discovery = await fetch(base);
  assert.equal(discovery.status, 200);
  assert.match(discovery.headers.get('content-type'), /^text\/markdown/);
  const expectedDiscovery = [
    '# Stagehand',
    '',
    'Stagehand lets external tools inspect and control Greeter Demo through a JavaScript API.',
    '',
    'This server provides the client and documentation matching the installed integration:',
    '',
    '- [JavaScript client](./client.mjs)',
    '- [Stagehand API](./api.md)',
    '- [Greeter Demo API](./game.md)',
    '',
    'Stagehand clients connect using this server’s HTTP or HTTPS base address. RPC communication',
    'uses WebSocket at `/rpc`.',
    '',
  ].join('\n');
  assert.equal(await discovery.text(), expectedDiscovery);

  const reference = await fetch(base + '/api.md');
  assert.equal(reference.status, 200);
  assert.match(reference.headers.get('content-type'), /^text\/markdown/);
  const protocol = new URL('../../docs/protocol.md', import.meta.url);
  assert.equal(await reference.text(), await readFile(protocol, 'utf8'));

  const gameReference = await fetch(base + '/game.md');
  assert.equal(gameReference.status, 200);
  assert.match(gameReference.headers.get('content-type'), /^text\/markdown/);
  const gameDocs = new URL('../../tests/transport/served/game.md', import.meta.url);
  assert.equal(await gameReference.text(), await readFile(gameDocs, 'utf8'));

  const clientAsset = await fetch(base + '/client.mjs');
  assert.equal(clientAsset.status, 200);
  assert.match(clientAsset.headers.get('content-type'), /^text\/javascript/);
  const path = join(local, 'client.mjs');
  await writeFile(path, Buffer.from(await clientAsset.arrayBuffer()));

  const { connect: connectDownloaded } = await import(pathToFileURL(path));
  const client = await connectDownloaded(base, { token: fixture.token });
  t.after(() => client.close());
  const game = await client.builtin('Fixture');
  const message = 'from the matching client';
  assert.equal(await game.invoke('echo', { value: message }), message);

  await assert.rejects(connectDownloaded(base), { code: -32001 });
  assert.equal((await fetch(base + '/missing')).status, 404);
  assert.equal((await fetch(base + '/rpc', { method: 'POST' })).status, 405);
  const head = await fetch(base + '/client.mjs', { method: 'HEAD' });
  assert.equal(head.headers.get('content-length'), clientAsset.headers.get('content-length'));
  assert.equal(await head.text(), '');
  const large = await fetch(base + '/api.md', { headers: { 'X-Test': 'a'.repeat(8192) } });
  assert.equal(large.status, 431);
});

test('loopback rejects foreign Host and browser Origin independently of token setup', async (t) => {
  const fixture = await launchFixture({ fixture: 'transport', token: '' });
  t.after(fixture.stop);
  const base = fixture.url;

  for (const origin of ['https://example.invalid', 'null', '']) {
    const refused = await upgrade(base, { Origin: origin });
    assert.equal(refused.status, 403);
  }

  const badHost = 'example.invalid:' + new URL(base).port;
  assert.equal(await httpStatus(base + '/api.md', { Host: badHost }), 403);
  assert.equal((await upgrade(base, { Host: badHost })).status, 403);
  assert.equal((await upgrade(base, { 'Sec-WebSocket-Version': '12' })).status, 426);
  assert.equal((await upgrade(base, { 'Sec-WebSocket-Key': 'not-a-nonce' })).status, 400);

  const client = await connect(fixture.url);
  t.after(() => client.close());
  assert.equal(await (await client.builtin('Fixture')).invoke('echo', { value: true }), true);
});

test('standard extended lengths and fragmented replies work with the default client', async (t) => {
  const fixture = await launchFixture({ fixture: 'transport' });
  t.after(fixture.stop);
  const client = await connect(fixture.url, { token: fixture.token });
  t.after(() => client.close());
  const game = await client.builtin('Fixture');

  for (const size of [256, 256 * 1024, 2 * 1024 * 1024]) {
    const value = 'x'.repeat(size);
    assert.ok(await game.invoke('echo', { value }) === value, `${size} bytes round-trip`);
  }
});

test('fragmented UTF-8 text survives split TCP writes and an interleaved ping', async (t) => {
  const fixture = await launchFixture({ fixture: 'transport', token: '' });
  t.after(fixture.stop);
  const { status, socket } = await upgrade(fixture.url);
  assert.equal(status, 101);
  t.after(() => socket.destroy());

  const request = Buffer.from(JSON.stringify({
    jsonrpc: '2.0', id: '🌱', method: 'session.hello',
  }));
  const split = request.indexOf(Buffer.from('🌱')) + 1;
  const first = frame(1, request.subarray(0, split), { final: false });
  socket.write(first.subarray(0, 4));
  await delay(35);
  socket.write(Buffer.concat([
    first.subarray(4), frame(9, Buffer.from('x')), frame(0, request.subarray(split)),
  ]));

  const [pong, reply] = await readFrames(socket, 2);
  assert.equal(pong.opcode, 10);
  assert.equal(pong.body.toString(), 'x');
  assert.equal(reply.opcode, 1);
  assert.equal(JSON.parse(reply.body).id, '🌱');

  socket.write(frame(8, Buffer.from([3, 232])));
  const [close] = await readFrames(socket, 1);
  assert.equal(close.opcode, 8);
  assert.equal(close.body.readUInt16BE(), 1000);
});

test('invalid frames use standard close codes before reaching the RPC dispatcher', async (t) => {
  const fixture = await launchFixture({ fixture: 'transport', token: '' });
  t.after(fixture.stop);
  const base = fixture.url;

  const cases = [
    { label: 'unmasked client frame', bytes: Buffer.from([0x81, 0]), code: 1002 },
    { label: 'unexpected continuation', bytes: frame(0), code: 1002 },
    {
      label: 'fragmented control frame',
      bytes: frame(9, Buffer.alloc(0), { final: false }),
      code: 1002,
    },
    { label: 'binary message', bytes: frame(2), code: 1003 },
    { label: 'invalid UTF-8', bytes: frame(1, Buffer.from([0xe0, 0x80, 0x80])), code: 1007 },
    { label: 'invalid close payload', bytes: frame(8, Buffer.from([3])), code: 1002 },
  ];

  const oversized = Buffer.alloc(14);
  oversized[0] = 0x81;
  oversized[1] = 0xff;
  oversized.writeBigUInt64BE(8n * 1024n * 1024n + 1n, 2);
  cases.push({ label: 'oversized message', bytes: oversized, code: 1009 });

  const continuation = Buffer.from(oversized);
  continuation[0] = 0x80;
  continuation.writeBigUInt64BE(8n * 1024n * 1024n, 2);
  const fragments = Buffer.concat([frame(1, Buffer.from('x'), { final: false }), continuation]);
  cases.push({ label: 'fragmented message exceeds the limit', bytes: fragments, code: 1009 });

  for (const { label, bytes, code } of cases) {
    const { socket } = await upgrade(base);
    try {
      socket.write(bytes);
      const [close] = await readFrames(socket, 1);
      assert.equal(close.opcode, 8, label);
      assert.equal(close.body.readUInt16BE(), code, label);
    } finally {
      socket.destroy();
    }
  }
});

function frame(opcode, payload = Buffer.alloc(0), { final = true } = {}) {
  assert.ok(payload.length < 126);
  const mask = [1, 2, 3, 4];
  const bytes = Buffer.from([(final ? 0x80 : 0) | opcode, 0x80 | payload.length, ...mask]);
  const body = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
  return Buffer.concat([bytes, body]);
}

async function readFrames(socket, count) {
  const frames = [];
  let bytes = Buffer.alloc(0);
  for await (const chunk of socket.iterator({ destroyOnReturn: false })) {
    bytes = Buffer.concat([bytes, chunk]);
    while (bytes.length >= 2) {
      const opcode = bytes[0] & 0xf;
      let length = bytes[1];
      let offset = 2;
      assert.ok(length < 127, 'test reader expects small control or session frames');
      if (length === 126) {
        if (bytes.length < 4) break;

        length = bytes.readUInt16BE(2);
        offset = 4;
      }
      if (bytes.length < offset + length) break;

      frames.push({ opcode, body: bytes.subarray(offset, offset + length) });
      bytes = bytes.subarray(offset + length);
      if (frames.length === count) return frames;
    }
  }

  throw new Error('WebSocket closed before the expected frames arrived');
}

function httpStatus(url, headers) {
  return new Promise((resolve, reject) => {
    const req = get(url, { headers }, (response) => {
      response.resume();
      resolve(response.statusCode);
    });
    req.on('error', reject);
  });
}

function upgrade(base, extra = {}) {
  return new Promise((resolve, reject) => {
    const req = get(base + '/rpc', {
      headers: {
        Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==', ...extra,
      },
    });
    req.on('response', (res) => {
      res.resume();
      resolve({ status: res.statusCode });
    });
    req.on('upgrade', (res, socket, head) => {
      socket.setTimeout(3500, () => socket.destroy(new Error('fixture frame timeout')));
      if (head.length) socket.unshift(head);

      resolve({ status: res.statusCode, socket });
    });
    req.on('error', reject);
  });
}
