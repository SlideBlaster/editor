# common (port types)

Small types shared by more than one port, kept here to avoid cross-port imports
for incidental shapes.

- `Unsubscribe` — a zero-arg function returned by subscription-style calls
  (`StoragePort.watch`, `Session.onSync`, `Awareness.on`). Calling it detaches the
  listener; calling it twice is a no-op.

No runtime behavior; type-only module.
