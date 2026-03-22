export function get(name) {
  const value = process.env[name];
  return value === undefined ? { tag: "Error", error: undefined } : { tag: "Ok", value };
}

export function set(name, value) {
  process.env[name] = value;
}

export function unset(name) {
  delete process.env[name];
}
