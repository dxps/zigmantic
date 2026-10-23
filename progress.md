# Zigmantic Progress

This file is the durable handoff record for work performed across sessions and systems.
Update it whenever scope, architecture, conformance, or implementation status changes.

## Mission

Build a pure Zig semantic-web toolkit with standards-oriented implementations of RDF,
SPARQL, entailment, SHACL, and ShEx. Avoid Rust or C runtime dependencies in the core
library. Applications should be able to select only the modules they need.

## Scope decisions

- The implementation will target standards conformance rather than compatibility with
  any particular existing repository or implementation.
- RDF 1.1 Concepts and Abstract Syntax is the foundational conformance target.
- Turtle, TriG, N-Triples, and N-Quads will receive full parsers, serializers, and W3C
  test-suite coverage.
- RDF 1.1 Semantics and RDF Schema entailment will be implemented as explicit layers;
  a store will not silently infer triples unless requested.
- RDF/XML is part of the long-term RDF 1.1 suite target, but is deferred until the core
  data model and the four text syntaxes above are conformant.
- SPARQL 1.1 Query and Update are long-term full targets, delivered incrementally by
  algebra feature rather than by hard-coded example queries.
- OWL support targets the OWL 2 RL/RDF rules, not unrestricted OWL 2 DL reasoning.
- SHACL targets SHACL Core first and SHACL-SPARQL after the SPARQL engine is mature.
- ShEx targets ShEx 2.1, including ShExC and shape maps.
- RDF/SPARQL 1.2 features will remain experimental until the 1.1 baseline is stable.

## Proposed module layout

- `rdf`: RDF terms, triples, graphs, quads, datasets, vocabularies.
- `rdf_io`: tokenization, parsing, and serialization for RDF syntaxes.
- `store`: indexed in-memory dataset and transaction interfaces.
- `sparql`: parser, algebra, optimizer, query evaluation, results, and updates.
- `entailment`: RDF, RDFS, and OWL 2 RL rule materialization.
- `shacl`: shapes graph loading, targeting, validation, and reports.
- `shex`: ShExC parsing, shape maps, and validation.
- `zigmantic`: stable umbrella API over the modules above.

All modules initially live in one Zig package and repository. They may be published as
separate packages only after their APIs and release cycles become independently stable.

## Milestones

1. Project skeleton, error model, allocators, test conventions, and conformance harness.
2. RDF 1.1 data model with canonical term comparison, hashing, ownership, and graph/dataset APIs.
3. Complete N-Triples and N-Quads parsers/serializers plus W3C syntax tests.
4. Complete Turtle and TriG parsers/serializers plus W3C syntax/evaluation tests.
5. Indexed in-memory quad store, named graphs, transactions, and deterministic iteration APIs.
6. RDF/RDFS semantics and entailment test coverage.
7. SPARQL 1.1 parser and algebra, followed by Query evaluation and result formats.
8. SPARQL 1.1 Update and graph-store operations.
9. OWL 2 RL forward-chaining and applicable W3C conformance tests.
10. SHACL Core validation and standard RDF validation reports.
11. SHACL-SPARQL constraints.
12. ShEx 2.1 parsing, shape maps, and validation.
13. Deferred RDF/XML support and a complete RDF 1.1 suite audit.
14. Experimental RDF/SPARQL 1.2 support behind an explicit feature boundary.

## Conformance policy

- Each claimed specification feature must have normative-spec references and tests.
- Prefer official W3C test suites; record exclusions and disputed tests explicitly.
- Do not describe a module as conformant while required tests are skipped silently.
- Fuzz parsers and verify parse/serialize/parse round trips.
- Keep inference deterministic and separate asserted from inferred statements.

## Current status

- 2026-10-23: Standalone project directory identified as the implementation target.
- 2026-10-23: Initial scope and roadmap recorded.
- 2026-10-23: Zig 0.17.0 package and test scaffolding implemented.
- 2026-10-23: Initial RDF 1.1 core model implemented with dataset-owned string and term
  interning, compact term identifiers, borrowed views, triples, quads, graphs, datasets,
  RDF position validation, and set semantics.
- 2026-10-23: Ownership and validation boundaries documented in `docs/architecture.md`.
- RDF term equality and deterministic hashing now work across independent term pools.
- Graph and dataset pattern iterators provide allocation-free statement filtering.
- Nine RDF core tests pass under `zig build test`.

## Milestone status

- Milestone 1 — project skeleton and conventions: complete.
- Milestone 2 — RDF 1.1 data model: in progress.
- Milestones 3–14: not started.

## Next actions

1. Expand constructor edge-case and allocation-failure tests.
2. Add the official RDF test manifests to the conformance harness without yet vendoring
   generated artifacts.
3. Begin the N-Triples tokenizer only after the RDF data-model API is stable.

## Session log

### 2026-10-23 — Initial planning

- Chose a standards-oriented pure Zig implementation.
- Chose one package with multiple modules.
- Made RDF 1.1 Concepts the first complete normative target.
- Deferred RDF/XML and RDF/SPARQL 1.2 until the core 1.1 implementation is stable.
- Confirmed that `zigmantic` is a standalone repository with no source dependency on
  another project repository.

### 2026-10-23 — Initial implementation

- Added the Zig 0.17.0 package manifest and build/test graph.
- Added the public `zigmantic` module and initial `rdf` module.
- Implemented allocator-owned term interning with `TermId` handles and borrowed views.
- Implemented RDF 1.1 literal invariants for `xsd:string` and `rdf:langString`.
- Implemented triples, quads, graphs, datasets, named graphs, validation, and set semantics.
- Added an explicit public error set and six passing unit tests.
- Added `docs/architecture.md` for durable ownership and API decisions.
- Added a minimal package readme.

### 2026-10-23 — RDF comparison and iteration

- Added value-based term equality across independent term pools.
- Added deterministic term hashing consistent with term equality.
- Added allocation-free triple and quad pattern iterators.
- Documented identifier and pattern-matching semantics.
- Added three focused unit tests.
