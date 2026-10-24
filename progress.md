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
- Constructor edge cases cover Unicode, empty lexical forms, datatype distinctions,
  malformed UTF-8, and structurally invalid identifiers.
- Exhaustive allocation-failure injection covers graph and dataset construction without
  leaks or swallowed out-of-memory errors.
- Eleven RDF core tests pass under `zig build test`.
- The `rdf_io` module now contains the first incremental RDF 1.1 N-Triples parser.
- The official W3C RDF 1.1 N-Triples manifest and its 70 referenced inputs are vendored
  at revision `bfefa770267ec0e5b6e45764bbca4ee43789ba72` with upstream provenance and license.
- Five N-Triples parser tests pass; the complete suite currently has 16 passing tests.
- All 70 W3C positive and negative N-Triples syntax cases pass through the manifest-driven
  conformance runner.
- Canonical N-Triples serialization, exact Unicode blank-node label validation, and
  stable parse/serialize/parse round trips are implemented.
- N-Quads parsing and canonical serialization reuse the validated N-Triples term grammar
  and support default, IRI-named, and blank-node-named graphs.
- The local suite has 24 tests; all 70 official N-Triples syntax cases continue to pass.
- The official W3C RDF 1.1 N-Quads manifest and its 87 referenced inputs are vendored
  at revision `bfefa770267ec0e5b6e45764bbca4ee43789ba72` with provenance and license.
- All 157 official N-Triples and N-Quads positive and negative syntax cases pass.
- The whole-document RDF line-syntax API now has documented ownership, ordering, and
  error guarantees in `docs/api.md`.
- The public `iri` module implements allocator-owned RFC 3986/3987 relative IRI
  resolution and passes the RFC normal and abnormal example tables.
- The first Turtle parser slice supports both Turtle and SPARQL-style base/prefix
  directives, relative IRI references, prefixed names, `a`, comments, and simple
  resource-only triples.
- Turtle now supports labeled blank nodes; short and long single- or double-quoted
  strings; language and explicit datatype suffixes; and native integer, decimal,
  double, and boolean literals.
- Predicate lists, object lists, trailing predicate separators, and empty anonymous
  blank nodes now expand directly into graph triples. Anonymous-node allocation is
  collision-safe with source blank-node labels.
- Non-empty blank-node property lists now expand recursively in subject and object
  positions, including nested lists with their own predicate and object lists.
- RDF collections now expand into `rdf:first`/`rdf:rest` chains ending in `rdf:nil`,
  including empty collections and nested collection/property-list items.
- The local suite has 40 tests; all 157 official N-Triples and N-Quads syntax cases
  continue to pass.
- The official RDF 1.1 Turtle manifest and its action/result files are vendored at the
  same pinned W3C revision as the line-syntax suites.
- The manifest runner executes all 313 Turtle syntax and evaluation entries. Evaluation
  uses RDF graph isomorphism so blank-node labels need not match.
- All 313 official RDF 1.1 Turtle positive syntax, negative syntax, and evaluation cases
  now pass with no exclusions.
- Deterministic expanded Turtle serialization emits one absolute-IRI triple per line and
  round trips nested Turtle graphs stably without reconstructing syntactic shorthand.
- The local suite has 43 tests; all 470 official RDF syntax/evaluation cases pass.

## Milestone status

- Milestone 1 — project skeleton and conventions: complete.
- Milestone 2 — RDF 1.1 data model: substantially complete; API review remains.
- Milestone 3 — N-Triples and N-Quads: complete.
- Milestone 4 — Turtle and TriG: in progress; Turtle parsing and serialization are
  complete, while TriG remains.
- Milestones 5–14: not started.

## Next actions

1. Begin TriG graph syntax using the shared Turtle lexer and parser foundations.
2. Add named-graph blocks and default-graph blocks returning an owned dataset.
3. Pin the official TriG suite and drive syntax/evaluation conformance.

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

### 2026-10-23 — RDF robustness

- Added constructor edge-case coverage for RDF term distinctions and invalid input.
- Added exhaustive allocation-failure tests for graph and dataset ownership paths.
- Verified that allocation failures propagate and all partially built state is reclaimed.

### 2026-10-23 — N-Triples foundation

- Added the public `rdf_io` module and an owned-graph N-Triples parsing API.
- Implemented line grammar, comments, RDF term forms, language and datatype suffixes,
  string escapes, Unicode escapes, UTF-8 checks, and duplicate elimination.
- Added parser syntax, semantic, and exhaustive allocation-failure tests.
- Recorded the official W3C RDF 1.1 N-Triples test manifest source.

### 2026-10-23 — N-Triples conformance harness

- Pinned the W3C RDF test repository to an immutable revision.
- Vendored only the RDF 1.1 N-Triples manifest and its 70 referenced inputs, retaining
  upstream provenance and licensing.
- Added a manifest-driven Zig runner for all positive and negative syntax cases.
- Corrected term-separation handling: whitespace is optional where adjacent terminals
  are unambiguous.
- Passed all 70 official syntax cases and all 16 local unit tests.

### 2026-10-23 — N-Triples serialization

- Added canonical-layout N-Triples serialization with deterministic graph-order output.
- Added required literal escaping and compact language/datatype suffixes.
- Implemented the complete Unicode range checks for N-Triples blank-node labels.
- Rejected programmatic blank-node identifiers that cannot be represented in N-Triples.
- Added byte-exact output, stable round-trip, Unicode boundary, and allocation-failure
  coverage while retaining a full pass of the official syntax manifest.

### 2026-10-24 — N-Quads implementation

- Refactored the private line parser to share term grammar without changing the public
  N-Triples API.
- Added owned-dataset `parseNQuads` and canonical-layout `serializeNQuadsAlloc` APIs.
- Supported default graphs plus IRI and blank-node graph labels.
- Added invalid graph-label, extra-term, byte-exact output, stable round-trip, and
  exhaustive allocation-failure coverage.
- Retained a full pass of the official N-Triples syntax manifest.

### 2026-10-24 — N-Quads conformance

- Pinned and vendored the official RDF 1.1 N-Quads manifest and all 87 referenced
  inputs at the same W3C test-repository revision as N-Triples.
- Retained upstream provenance and the W3C test-suite license.
- Extracted a shared manifest runner used by both line-syntax suites.
- Ensured each input buffer is released immediately after its case completes.
- Passed all 87 N-Quads and all 70 N-Triples official syntax cases.
- Marked the N-Triples and N-Quads milestone complete.

### 2026-10-24 — RDF line-syntax API review

- Documented ownership and ordering guarantees for parsing and serialization.
- Replaced the broad parser error union with `ParseError`, limited to allocation,
  malformed UTF-8, and invalid syntax failures.
- Renamed the shared serializer failure to `InvalidBlankNodeLabel` so it accurately
  describes both N-Triples and N-Quads behavior.
- Kept whole-document APIs separate from future streaming APIs.
- Retained all 24 local tests and all 157 official syntax cases.

### 2026-10-24 — IRI reference resolution

- Added a public, allocator-owned `iri.resolveAlloc` API with explicit `ResolveError`.
- Implemented RFC 3986 component parsing, path merging, dot-segment removal, and
  recomposition for absolute and relative references.
- Applied the same algorithm to UTF-8 IRI references according to RFC 3987 section 6.5.
- Preserved Unicode text, percent-escape spelling, queries, and fragments without
  dereferencing or optional normalization.
- Covered the RFC 3986 normal and abnormal resolution examples, Unicode IRIs, invalid
  bases and references, malformed UTF-8, and exhaustive allocation failures.

### 2026-10-24 — Turtle directive and IRI foundation

- Added an allocator-owned `parseTurtle` API with an optional external base IRI.
- Established lexer tokens for comments, directives, IRI references, prefixed names,
  `a`, statement terminators, and end of input.
- Implemented `@base`/`@prefix` and case-insensitive `BASE`/`PREFIX` directives.
- Resolved relative references through the shared RFC 3986/3987 IRI module and expanded
  default and named prefixes.
- Parsed simple resource-only triples, including the `a` shorthand for `rdf:type`.
- Added invalid-directive, unresolved-name, external-base, and exhaustive
  allocation-failure tests.
- Passed all 32 local tests and retained all 157 official N-Triples/N-Quads cases.
- Kept the API and documentation explicit that this is an incremental subset, not a
  Turtle conformance claim.

### 2026-10-24 — Turtle literals and labeled blank nodes

- Added labeled blank nodes in subject and object positions with stable identity.
- Added short and long single- and double-quoted strings with Turtle escape decoding.
- Added language-tagged and explicitly typed literals, including prefixed datatypes.
- Assigned the required XSD datatypes to integer, decimal, double, and boolean tokens
  while preserving their lexical forms.
- Handled the contextual ambiguity between directive tokens and the valid `@base` and
  `@prefix` language tags.
- Added semantic term-value checks, malformed-input cases, and allocation-failure
  coverage for the new forms.
- Passed all 35 local tests and retained all 157 official N-Triples/N-Quads cases.

### 2026-10-24 — Turtle lists and anonymous blank nodes

- Added predicate lists separated by `;`, including repeated trailing separators.
- Added comma-separated object lists and emitted their Cartesian statement expansion in
  source order.
- Added empty `[]` blank nodes in subject and object positions.
- Made generated blank-node identifiers collision-safe with explicit source labels,
  including labels that match the internal generation pattern.
- Reused one subject across every expanded statement and preserved graph set semantics.
- Added malformed-list, unsupported-property-list, identity, expansion-order, and
  allocation-failure coverage.
- Passed all 37 local tests and retained all 157 official N-Triples/N-Quads cases.

### 2026-10-24 — Turtle blank-node property lists

- Reused the predicate/object expansion routine for top-level statements and property
  lists so their separator behavior remains identical.
- Added non-empty property lists in both subject and object positions.
- Added recursive nesting with stable links between enclosing and nested blank nodes.
- Preserved empty `[]` behavior and collision-safe generated identifiers.
- Added semantic identity checks, malformed-list cases, and allocation-failure coverage
  using nested structures.
- Passed all 38 local tests and retained all 157 official N-Triples/N-Quads cases.

### 2026-10-24 — Turtle RDF collections

- Added empty and non-empty collections in subject and object positions.
- Expanded collection cells into `rdf:first` and `rdf:rest` statements ending in the
  interned `rdf:nil` IRI.
- Supported literals, resources, property lists, empty collections, and nested
  collections as list items.
- Preserved collision-safe blank-node generation for collection cells.
- Added exact chain-identity, empty-list, nested-structure, malformed-input, and
  allocation-failure coverage.
- Passed all 40 local tests and retained all 157 official N-Triples/N-Quads cases.

### 2026-10-24 — Turtle conformance harness

- Pinned and vendored the official RDF 1.1 Turtle manifest, action inputs, expected
  N-Triples graphs, provenance, and test-suite license at the existing W3C revision.
- Added a manifest-list reader that executes all 313 listed cases rather than scanning
  or silently omitting test definitions.
- Distinguished positive syntax, negative syntax, and evaluation cases.
- Added blank-node-insensitive graph isomorphism for evaluation results.
- Established an executable baseline of 295 passing cases and 18 exact known failures;
  regressions and newly passing cases both require deliberate baseline updates.
- Retained all 40 local tests and all 157 N-Triples/N-Quads cases.

### 2026-10-24 — Turtle parser conformance

- Made Turtle word scanning aware of escaped delimiters such as `\#`, `\,`, and `\;`.
- Implemented the complete Unicode `PN_PREFIX`, `PN_LOCAL`, percent-escape, and reserved
  local-name escape grammar while preserving percent escapes in expanded IRIs.
- Reused the Unicode PN character classifier shared with blank-node label validation.
- Required an alphabetic first character for RDF language tags.
- Accepted standalone non-empty blank-node property lists while continuing to reject
  standalone empty anonymous nodes.
- Eliminated all 18 tracked failures and passed all 313 official Turtle cases with no
  exclusions, alongside 40 local and 157 line-syntax cases.

### 2026-10-24 — Turtle serialization

- Added allocator-owned `serializeTurtleAlloc` output.
- Chose deterministic expanded Turtle using the N-Triples-compatible subset rather than
  inventing prefixes or heuristically reconstructing source shorthand.
- Shared the graph-writing implementation with canonical-layout N-Triples serialization.
- Preserved graph iteration order, term lexical forms, language tags, datatypes, and
  explicit blank-node identity.
- Added byte-exact output and stable parse/serialize/parse coverage using nested property
  lists and collections.
- Added exhaustive allocation-failure coverage for parsing and Turtle serialization.
- Passed all 43 local tests and all 470 official RDF syntax/evaluation cases.
