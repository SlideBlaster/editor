# Tauri-fs binding (tauriFs.ts)

The desktop peer of adapters-native/node.ts: it supplies the runtime pieces
`createNativeWorkspace` needs INSIDE the Tauri webview (which has no Node), both over
`@tauri-apps/plugin-fs`. The SAME tested Storage + Git logic runs on top of it — the only
difference from the CLI/test path is this binding.

## Contract

- `tauriFs` — a `PromiseFsClient` over plugin-fs. Absolute OS paths (from the folder
  picker); no `baseDir`. plugin-fs has no `unlink`/`rmdir`, so both map to `remove` (a
  non-recursive `remove` deletes a file or an empty dir, matching the isomorphic-git
  contract). `stat`/`lstat` map plugin `FileInfo` to the stat shape isomorphic-git expects
  (methods + `mtimeMs`/`mode`/...) and translate "missing" to an `ENOENT`-coded error;
  `mkdir` translates "already exists" to `EEXIST`, the codes the storage adapter and
  isomorphic-git test against. Symlinks are unsupported (outside the working-copy model).
- `tauriWatch` — a `NativeWatch` over plugin-fs `watchImmediate`. Because plugin-fs resolves
  the watcher asynchronously while `NativeWatch` returns synchronously, the returned
  unsubscribe stops the watcher whenever it eventually attaches. Create/modify/remove kinds
  map to create/update/delete; access/other are ignored; paths outside the root are dropped.
  Best-effort, per the port contract.

## Validation

Typechecked against the plugin-fs types only. It CANNOT run headlessly — plugin-fs requires
a live Tauri webview — so runtime behaviour (especially the isomorphic-git stat shape and
error-code mapping) must be validated on a Tauri-toolchain machine.

## Relations

- Injected into `createNativeWorkspace` (../../adapters-native/src/workspace.md) by
  [main.md](./main.md). Node peer: ../../adapters-native/src/node.md.
