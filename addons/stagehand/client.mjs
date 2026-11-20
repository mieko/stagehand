import { EventEmitter } from 'node:events';

const wrappedObjects = new WeakMap();
const pendingCaptures = new WeakMap();

export class GodotValue {
  constructor(native) {
    this.native = native;
  }

  get type() {
    return this.native.type;
  }

  get args() {
    return this.native.args;
  }

  toJSON() {
    return { $godot: this.native };
  }
}

function decode(value, client) {
  if (Array.isArray(value)) {
    return value.map((item) => decode(item, client));
  }

  if (value && typeof value === 'object') {
    if (Object.hasOwn(value, '$ref')) {
      return client.object(value.$ref, value.$type);
    }

    if (Object.hasOwn(value, '$dictionary')) {
      return new Map(
        value.$dictionary.map(([key, item]) => [decode(key, client), decode(item, client)]),
      );
    }

    if (Object.hasOwn(value, '$godot')) {
      const native = value.$godot;
      if (typeof native === 'string') {
        if (native.startsWith('i:')) {
          return BigInt(native.slice(2));
        }

        if (native.startsWith('f:')) {
          return { inf: Infinity, '-inf': -Infinity, nan: NaN }[native.slice(2)];
        }

        if (native.startsWith('sn:')) {
          return native.slice(3);
        }
      }

      return new GodotValue(native);
    }

    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, decode(item, client)]),
    );
  }

  return value;
}

function encode(value, depth = 0) {
  if (depth > 16) {
    throw new TypeError('Value is cyclic or exceeds the maximum nesting depth');
  }

  value = wrappedObjects.get(value) ?? value;

  const next = (item) => encode(item, depth + 1);
  if (typeof value === 'bigint') {
    return { $godot: `i:${value}` };
  }

  if (typeof value === 'number' && !Number.isFinite(value)) {
    return { $godot: `f:${Number.isNaN(value) ? 'nan' : value < 0 ? '-inf' : 'inf'}` };
  }

  if (value instanceof RemoteObject) {
    return { $ref: value.id };
  }

  if (value instanceof GodotValue) {
    return value.toJSON();
  }

  if (value instanceof Map) {
    return { $dictionary: [...value].map(([key, item]) => [next(key), next(item)]) };
  }

  if (Array.isArray(value)) {
    return value.map(next);
  }

  if (value && typeof value === 'object') {
    if (Object.keys(value).some((key) => ['$ref', '$godot', '$dictionary'].includes(key))) {
      return { $dictionary: Object.entries(value).map(([key, item]) => [key, next(item)]) };
    }

    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, next(item)]));
  }

  return value;
}

export class RemoteObject {
  constructor(client, id) {
    this.client = client;
    this.id = id;
  }

  describe() {
    return this.client.request('object.describe', { object: this.id });
  }

  observe() {
    return this.client.request('object.observe', { object: this.id });
  }

  invoke(method, params = {}) {
    return this.client.request('object.call', { object: this.id, method, params });
  }

  subscribe(event, listener) {
    return this.client.subscribe(this.id, event, listener);
  }

  async inspect() {
    return (await this.client.root('Object')).inspect({ target: this });
  }

  async get(property) {
    return (await this.client.root('Object')).get({ target: this, property });
  }

  async set(property, value) {
    return (await this.client.root('Object')).set({ target: this, property, value });
  }

  async call(method, ...args) {
    return (await this.client.root('Object')).call({ target: this, method, args });
  }
}

export function forwardMethods(names) {
  if (!Array.isArray(names)) {
    throw new TypeError('Expected an array of operation names');
  }

  const methods = [...names];
  if (methods.some((name) =>
    typeof name !== 'string' || !name || name === 'remote' || name === 'then')) {
    throw new TypeError('Expected operation names other than "remote" or "then"');
  }

  return (remote) => Object.fromEntries([
    ['remote', remote],
    ...methods.map((name) => [name, (params) => remote.invoke(name, params)]),
  ]);
}

export class InputObject extends RemoteObject {
  async startSequence(params) {
    return this.#startAction('sequence', params);
  }

  async startMouseMove(params) {
    return this.#startAction('move_mouse_to', params);
  }

  async startHoldUntil(params) {
    return this.#startAction('hold_until', params);
  }

  async #startAction(method, params) {
    let resolve, reject, action;
    const early = [];
    const finished = new Promise((done, failed) => {
      resolve = done;
      reject = failed;
    });
    // Callers may await acceptance before attaching their outcome handler.
    finished.catch(() => {});

    const closed = () =>
      reject(new Error('Stagehand connection closed; action outcome is unknown'));
    const removed = (item) => {
      if (item.method === 'objects.removed' && item.params.object === this.id)
        reject(new Error('Action endpoint was removed'));
    };
    this.client.once('close', closed);
    this.client.on('notification', removed);

    const unsubscribe = await this.subscribe('completed', (event) => {
      if (!action) early.push(event.value);
      else if (event.value.action === action) resolve(event.value);
    }).catch((error) => {
      this.client.off('close', closed);
      this.client.off('notification', removed);

      throw error;
    });

    try {
      const accepted = await this.invoke(method, params);
      action = accepted.action;
      for (const result of early) if (result.action === action) resolve(result);

      const cleaned = finished.finally(() => {
        this.client.off('close', closed);
        this.client.off('notification', removed);
        unsubscribe().catch(() => {});
      });
      cleaned.catch(() => {});

      return {
        ...accepted,
        finished: cleaned,
        cancel: () => this.invoke('cancel', { action }),
        getStatus: () => this.invoke('status', { action }),
      };
    } catch (error) {
      this.client.off('close', closed);
      this.client.off('notification', removed);
      await unsubscribe().catch(() => {});

      throw error;
    }
  }

  async sequence(params) {
    return (await this.startSequence(params)).finished;
  }

  async moveMouseTo(params) {
    return (await this.startMouseMove(params)).finished;
  }

  async holdUntil(params) {
    return (await this.startHoldUntil(params)).finished;
  }

  moveMouse(params) {
    return this.invoke('move_mouse', params);
  }
}

export class ScreenObject extends RemoteObject {
  capture(params = {}) {
    // The server retains one large capture per connection while we read its chunks.
    const previous = pendingCaptures.get(this.client) ?? Promise.resolve();
    const capture = previous.then(() => this.#capture(params));
    pendingCaptures.set(this.client, capture.then(() => {}, () => {}));

    return capture;
  }

  async #capture(params) {
    const { base64, byte_length: length, ...info } = await this.invoke('capture', params);
    if (base64 !== undefined) {
      return { ...info, image: Buffer.from(base64, 'base64') };
    }

    if (!Number.isSafeInteger(length) || length <= 0) {
      throw new Error('Invalid screenshot length');
    }

    const chunks = [];
    let offset = 0;
    while (offset < length) {
      const page = await this.invoke('capture_chunk', { capture: info.capture, offset });
      const chunk = Buffer.from(page.base64, 'base64');
      if (
        chunk.length === 0 || page.next_offset !== offset + chunk.length || page.next_offset > length
      ) {
        throw new Error('Invalid screenshot chunk');
      }

      chunks.push(chunk);
      offset = page.next_offset;
    }

    return { ...info, image: Buffer.concat(chunks, length) };
  }
}

function builtinMethods(names, Wrapper = RemoteObject) {
  const forward = forwardMethods(names);

  return remote => Object.assign(new Wrapper(remote.client, remote.id), forward(remote));
}

const defaultWrappers = {
  Registry: builtinMethods(['list']),
  Runtime: builtinMethods(['info']),
  SceneTree: builtinMethods(['current', 'query']),
  Object: builtinMethods(['inspect', 'get', 'set', 'call']),
  Script: builtinMethods(['evaluate']),
  PropertyRecorder: builtinMethods(['start', 'stop', 'read', 'discard', 'inspect']),
  Input: builtinMethods(
    ['actions', 'press', 'release', 'scroll', 'status', 'cancel'],
    InputObject,
  ),
  Screen: builtinMethods(['viewports', 'dimensions'], ScreenObject),
};

export class RpcError extends Error {
  constructor(error) {
    super(error.message);
    this.name = 'RpcError';
    this.code = error.code;
    this.data = error.data;
  }
}

export class StagehandClient extends EventEmitter {
  #socket;
  #pending = new Map();
  #nextId = 0;
  #subscriptions = new Map();
  #rootHandles = new Map();
  #types = new Map();

  constructor(socket, { wrappers = {} } = {}) {
    super();
    this.#socket = socket;
    this.wrappers = { ...wrappers };
    socket.addEventListener('message', ({ data }) => {
      const message = JSON.parse(data);
      for (const item of Array.isArray(message) ? message : [message]) {
        if (Object.hasOwn(item, 'id')) {
          const request = this.#pending.get(item.id);
          if (!request) {
            continue;
          }

          this.#pending.delete(item.id);
          clearTimeout(request.timer);
          if (item.error) {
            request.reject(new RpcError(item.error));
          } else {
            try {
              if (request.method === 'session.hello') this.#rememberObjects(item.result.objects);
              else if (request.method === 'objects.list') this.#rememberObjects(item.result);
              else if (request.method === 'object.describe') this.#rememberObjects([item.result]);
              request.resolve(decode(item.result, this));
            } catch (error) {
              request.reject(error);
            }
          }
        } else {
          try {
            if (item.method === 'objects.added') this.#rememberObjects([item.params]);
            item.params = decode(item.params, this);
          } catch (error) {
            this.emit('error', error);
            continue;
          }

          if (item.method === 'objects.removed') {
            this.#types.delete(item.params.object);
            for (const [label, id] of this.#rootHandles)
              if (id === item.params.object) this.#rootHandles.delete(label);
            for (const [id, subscription] of this.#subscriptions)
              if (subscription.object === item.params.object) this.#subscriptions.delete(id);
          }
          if (item.method === 'object.event') {
            this.#subscriptions.get(item.params.subscription)?.listener(item.params);
          }
          this.emit('notification', item);
        }
      }
    });
    socket.addEventListener('close', () => {
      for (const request of this.#pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error('Stagehand connection closed; operation outcome may be unknown'));
      }
      this.#pending.clear();
      this.#subscriptions.clear();
      this.#rootHandles.clear();
      this.#types.clear();
      this.emit('close');
    });
  }

  static async connect(
    address,
    { token, timeoutMs = 10_000, WebSocket: Socket = globalThis.WebSocket, wrappers = {} } = {},
  ) {
    const base = new URL(address);
    if (base.protocol !== 'http:' && base.protocol !== 'https:') {
      throw new TypeError('Stagehand address must start with http:// or https://');
    }

    if (base.pathname !== '/' || base.search || base.hash || base.username || base.password) {
      throw new TypeError('Use the Stagehand base address without a path, query, fragment, or credentials');
    }

    const rpc = new URL('/rpc', base.origin);
    rpc.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
    const socket = new Socket(rpc.href);
    const client = new StagehandClient(socket, { wrappers });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.close();
        reject(new Error('Stagehand connection timed out'));
      }, timeoutMs);
      socket.addEventListener(
        'open',
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true },
      );
      socket.addEventListener(
        'error',
        () => {
          clearTimeout(timer);
          reject(new Error('Cannot open Stagehand connection'));
        },
        { once: true },
      );
    });

    try {
      client.session = await client.request('session.hello', { token, protocol: 1 }, { timeoutMs });
      if (client.session.protocol !== 1) {
        throw new Error('Unsupported Stagehand protocol');
      }

      return client;
    } catch (error) {
      socket.close();

      throw error;
    }
  }

  request(method, params = {}, { timeoutMs = 10_000 } = {}) {
    if (this.#socket.readyState !== this.#socket.OPEN) {
      return Promise.reject(new Error('Stagehand is not connected'));
    }

    const id = String(++this.#nextId);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error('Request timed out; operation was not cancelled'));
      }, timeoutMs);
      this.#pending.set(id, { resolve, reject, timer, method });

      try {
        this.#socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params: encode(params) }));
      } catch (error) {
        clearTimeout(timer);
        this.#pending.delete(id);
        reject(error);
      }
    });
  }

  objects() {
    return this.request('objects.list');
  }

  #rememberObjects(descriptors) {
    for (const descriptor of descriptors) {
      this.#types.set(descriptor.id, descriptor.kind);
    }
  }

  object(id, type = this.#types.get(id)) {
    if (type !== undefined) this.#types.set(id, type);

    const remote = new RemoteObject(this, id);
    if (type === undefined) {
      return remote;
    }

    const standard = Object.hasOwn(defaultWrappers, type) ? defaultWrappers[type](remote) : remote;
    const wrapped = Object.hasOwn(this.wrappers, type) ? this.wrappers[type](standard) : standard;
    if (wrapped && typeof wrapped.then === 'function') {
      Promise.resolve(wrapped).catch(() => {});

      throw new TypeError('A wrapper factory must synchronously return an object');
    }

    if (wrapped === null || typeof wrapped !== 'object') {
      throw new TypeError('A wrapper factory must synchronously return an object');
    }

    const previous = wrappedObjects.get(wrapped);
    if (previous && (previous.client !== this || previous.id !== id)) {
      throw new TypeError('A wrapper instance already represents a different remote object');
    }

    wrappedObjects.set(wrapped, remote);

    return wrapped;
  }

  async #findDescriptor(label) {
    return (await this.objects()).find((object) => object.label === label);
  }

  async findObject(label) {
    const descriptor = await this.#findDescriptor(label);

    return descriptor ? this.object(descriptor.id) : null;
  }

  async root(label) {
    if (!this.#rootHandles.has(label)) {
      const descriptor = await this.#findDescriptor(label);
      if (!descriptor) {
        throw new Error(`Root is unavailable: ${label}`);
      }

      this.#rootHandles.set(label, descriptor.id);
    }

    return this.object(this.#rootHandles.get(label));
  }

  async subscribe(object, event, listener) {
    // Install the client-side router before resolving the subscription promise. The
    // notification router also buffers the acknowledgment-to-continuation gap.
    const early = [];
    const capture = (item) => {
      if (
        item.method === 'object.event' &&
        item.params.object === object &&
        item.params.event === event
      )
        early.push(item.params);
    };
    this.on('notification', capture);

    try {
      const id = await this.request('object.subscribe', { object, event });
      this.#subscriptions.set(id, { object, listener });
      for (const item of early) if (item.subscription === id) listener(item);

      return async () => {
        this.#subscriptions.delete(id);
        await this.request('object.unsubscribe', { subscription: id });
      };
    } finally {
      this.off('notification', capture);
    }
  }

  close() {
    this.#socket.close();
  }
}

export const connect = StagehandClient.connect;

const identifier = /^[_\p{XID_Start}][\p{XID_Continue}]*$/u;
const reserved = new Set([
  'as', 'and', 'assert', 'await', 'break', 'breakpoint', 'class', 'class_name', 'const',
  'continue', 'elif', 'else', 'enum', 'extends', 'for', 'func', 'if', 'in', 'is', 'match',
  'namespace', 'not', 'or', 'pass', 'preload', 'return', 'self', 'signal', 'static', 'super',
  'trait', 'var', 'void', 'while', 'when', 'yield', 'true', 'false', 'null', '_',
  'INF', 'NAN', 'PI', 'TAU', 'bindings', 'evaluate',
]);

function expression(value, name) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new TypeError(`${name} must be a nonempty GDScript expression`);
  }

  return value;
}

function record(value) {
  return value !== null && typeof value === 'object'
    && Object.prototype.toString.call(value) === '[object Object]';
}

export function gdPredicate(predicate, bindings = {}) {
  const observed = typeof predicate !== 'string';
  if (observed && (
    !record(predicate) || Object.keys(predicate).some((key) => !['value', 'matched'].includes(key))
  )) {
    throw new TypeError('Expected a predicate string or {value, matched}');
  }

  const matched = expression(observed ? predicate.matched : predicate, 'matched');
  const value = observed ? expression(predicate.value, 'value') : null;
  if (!record(bindings)) {
    throw new TypeError('Bindings must be an object of named values');
  }

  if (Object.getOwnPropertySymbols(bindings).length) {
    throw new TypeError('GDScript binding names must be strings');
  }

  const aliases = Object.keys(bindings).map((name) => {
    if (!identifier.test(name) || reserved.has(name) || (observed && name === 'value')) {
      throw new TypeError(`Invalid or reserved GDScript binding name: ${name}`);
    }

    return `\tvar ${name}: Variant = bindings[${JSON.stringify(name)}]`;
  });

  const body = [
    ...aliases,
    ...(aliases.length ? [''] : []),
    ...(observed ? [`\tvar value: Variant = ${value}`] : []),
    `\treturn {"matched": ${matched}, "value": ${observed ? 'value' : 'null'}}`,
  ];

  return {
    source: ['extends RefCounted', '', 'func evaluate(bindings: Dictionary) -> Dictionary:',
      ...body, ''].join('\n'),
    bindings,
  };
}
