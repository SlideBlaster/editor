import { describe, it, expectTypeOf } from 'vitest'
import type { AuthPort, GitPort, StoragePort, RemoteRef, ScopedToken } from './index'

// Type-level scaffolding smoke test: the barrel exports the port surface and the
// ports compose (Git remote operations carry an Auth-minted token). No runtime
// behavior exists yet; this pins the contract shape so M1 builds against it.
describe('ports barrel', () => {
  it('exposes the port interfaces', () => {
    expectTypeOf<StoragePort>().toBeObject()
    expectTypeOf<GitPort>().toBeObject()
    expectTypeOf<AuthPort>().toBeObject()
  })

  it('wires Auth tokens into Git remotes', () => {
    expectTypeOf<RemoteRef['token']>().toEqualTypeOf<ScopedToken>()
  })
})
