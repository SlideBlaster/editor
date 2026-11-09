/**
 * Browser-only project storage (W-web fallback): the same compare-and-replace semantics as
 * `/cap` `storage.save`, over IndexedDB. With no `sb serve` there is no native core, so in
 * the Desktop alpha this is used only for the fixture mode's draft persistence; it is the
 * storage half of the later in-page build.
 */
export interface KeyValueBackend {
  get(key: string): Promise<Uint8Array | undefined>;
  put(key: string, value: Uint8Array): Promise<void>;
  delete(key: string): Promise<void>;
  keys(): Promise<string[]>;
}

export class ConflictError extends Error {
  constructor(message: string) { super(message); this.name = "ConflictError"; }
}

const pathPattern = /^(?!\/)(?:[^/\0]+\/)*[^/\0]+$/;
export function checkPath(path: string): string {
  if (!pathPattern.test(path) || path.split("/").some((s) => s === ".." || s === ".")) throw new ConflictError(`bad path ${path}`);
  return path;
}

export interface ProjectStore {
  list(): Promise<{ path: string }[]>;
  read(path: string): Promise<Uint8Array | null>;
  /** `expected === null` means create-only; otherwise the stored bytes must equal `expected`. */
  save(path: string, expected: Uint8Array | null, content: Uint8Array): Promise<void>;
}

const same = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((v, i) => v === b[i]);

export function createProjectStore(backend: KeyValueBackend): ProjectStore {
  return {
    async list() { return (await backend.keys()).sort().map((path) => ({ path })); },
    async read(path) { return (await backend.get(checkPath(path))) ?? null; },
    async save(path, expected, content) {
      checkPath(path);
      const current = await backend.get(path);
      if (expected === null) { if (current !== undefined) throw new ConflictError(`${path} already exists`); }
      else if (current === undefined || !same(current, expected)) throw new ConflictError(`${path} changed since it was read`);
      await backend.put(path, content);
    },
  };
}

export function memoryBackend(): KeyValueBackend {
  const map = new Map<string, Uint8Array>();
  return {
    async get(key) { return map.get(key); },
    async put(key, value) { map.set(key, value.slice()); },
    async delete(key) { map.delete(key); },
    async keys() { return [...map.keys()]; },
  };
}

export function indexedDbBackend(name: string, factory: IDBFactory = indexedDB): KeyValueBackend {
  const open = () => new Promise<IDBDatabase>((resolve, reject) => {
    const request = factory.open(name, 1);
    request.onupgradeneeded = () => request.result.createObjectStore("files");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  const run = async <T>(mode: IDBTransactionMode, work: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> => {
    const db = await open();
    try {
      return await new Promise<T>((resolve, reject) => {
        const request = work(db.transaction("files", mode).objectStore("files"));
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
    } finally { db.close(); }
  };
  return {
    async get(key) { const v = await run<Uint8Array | undefined>("readonly", (s) => s.get(key)); return v === undefined ? undefined : new Uint8Array(v); },
    async put(key, value) { await run("readwrite", (s) => s.put(value, key)); },
    async delete(key) { await run("readwrite", (s) => s.delete(key)); },
    async keys() { return (await run<IDBValidKey[]>("readonly", (s) => s.getAllKeys())).map(String); },
  };
}
