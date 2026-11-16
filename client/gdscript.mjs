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
