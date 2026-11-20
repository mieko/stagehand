# Greeter Demo API

Download the [JavaScript client](./client.mjs). From Node.js 22 or newer, connect
with the game's base address and call the `Fixture` root to echo a value.

```js
const { connect } = await import('./client.mjs');
const game = await connect(address, { token });
const fixture = await game.root('Fixture');
console.log(await fixture.invoke('echo', { value: 'Hello!' }));
game.close();
```

See the [Stagehand API](./api.md) for the transport and standard endpoints.
