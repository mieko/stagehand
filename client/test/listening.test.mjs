import { test } from "node:test";
import assert from "node:assert/strict";
import { launchFixture } from "./fixture.mjs";
import { connect } from "../client.mjs";

test("localhost serves IPv4 and IPv6 on one port and one registered instance", async (t) => {
  const fixture = await launchFixture({ bindAddress: "localhost", builtins: null });
  t.after(() => fixture.stop());
  const port = new URL(fixture.url).port;
  const ipv4 = await connect(`http://127.0.0.1:${port}`, { token: fixture.token });
  t.after(() => ipv4.close());
  const ipv6 = await connect(`http://[::1]:${port}`, { token: fixture.token });
  t.after(() => ipv6.close());

  assert.equal(ipv4.session.instance, ipv6.session.instance);
  assert.deepEqual(await ipv4.objects(), await ipv6.objects());
});

test("explicit empty-token mode accepts a client without credentials", async (t) => {
  const fixture = await launchFixture({ token: "", builtins: null });
  t.after(() => fixture.stop());
  const client = await connect(fixture.url);
  t.after(() => client.close());

  const discovery = await fetch(fixture.url);
  const page = await discovery.text();
  assert.match(page, /^# Stagehand\n/);
  assert.match(page, /inspect and control this game through a JavaScript API\./);
  assert.doesNotMatch(page, /client\.mjs|api\.md|game\.md/);
  assert.equal((await fetch(new URL("/client.mjs", fixture.url))).status, 404);
  assert.equal((await fetch(new URL("/api.md", fixture.url))).status, 404);
  assert.equal((await fetch(new URL("/game.md", fixture.url))).status, 404);

  assert.equal(client.session.protocol, 1);
  assert.ok((await client.objects()).some((root) => root.kind === "Registry"));
});
