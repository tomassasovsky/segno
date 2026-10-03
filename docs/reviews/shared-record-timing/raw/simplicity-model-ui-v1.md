# Simplicity: model/UI

Base: `8749688c51912f808c3f36d4eb5bca665ede3ade`. Revision: the 21 exact working-tree hashes listed in `vgv-model-ui-v1.md`, verified before and after review with no drift. This is a bounded cross-author review of the model/UI producer and the new real-FFI snapshot test. The reviewer authored the runtime and does not certify that runtime here. One reviewer performed VGV, architecture, simplicity, and test-quality roles sequentially, using the complete corresponding workflow-agents role definitions; these are four perspectives, not four independent people.

Authority: repository AGENTS, build/tracking contract, and `docs/plan/2026-10-03-shared-record-timing.md`. No tests or product edits were performed during this review. Aggregate execution, coverage, native gates, current-head CI, saved design verification and final whole-change review are separate coordinator gates. No merge-ready claim is made.

## Result

No actionable simplification finding. The incremental implementation is appropriately small for the accepted nine-target capability; no speculative abstraction or compatibility behavior was found. No removals are recommended.

The two concrete target classes and one sealed family serve strict serialization, address conversion, typed dispatch and shared UI conversion. They reuse the seven-value enum instead of adding a second choice table. The same existing destination builder supplies External and MIDI. A fixed nine-target append is bounded and does not add I/O or real-time work.

Endpoint adapters extend the adjacent Record-length branches and keep raw Escape restoration separate from real edits. A generic discrete-control framework would broaden the scope without reducing the present behavioral complexity. Existing page length alone is not grounds for splitting unrelated flows. Likewise, retaining the pure owner port and repository mocks is required by the project’s architectural/testing boundaries.

The native interleaving test is a single bounded binding override with two literal tuples. It adds no production hook, test-only runtime mode or generic concurrency harness. Screenshot fixtures only extend established screenshot generation.
