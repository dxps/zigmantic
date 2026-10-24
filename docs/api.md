# Public API conventions

## Ownership

- `rdf.Graph`, `rdf.Dataset`, and `rdf.TermPool` own their allocations and require
  `deinit` with the same allocator lifetime used at construction.
- `rdf_io.parseNTriples` returns an owned `rdf.Graph`.
- `rdf_io.parseNQuads` returns an owned `rdf.Dataset`.
- `rdf_io.parseTurtle` returns an owned `rdf.Graph`.
- `rdf_io.parseTriG` returns an owned `rdf.Dataset`.
- `rdf_io.serializeNTriplesAlloc` and `rdf_io.serializeNQuadsAlloc` return owned byte
  slices that the caller frees with the allocator passed to the function.
- `rdf_io.serializeTurtleAlloc` and `rdf_io.serializeTriGAlloc` likewise return
  allocator-owned byte slices.
- Term views are borrowed and remain valid until their pool is deinitialized. Statement
  slices remain valid only while their container remains structurally unchanged.

Owned RDF containers and term pools must not be copied by value after initialization;
move them or pass pointers instead. Copying an owner would duplicate allocation handles
and make `deinit` unsafe.

## RDF data model

`TermId` is a compact handle meaningful only in its owning `TermPool`. Construct terms
through the named-node, blank-node, and literal interning functions. `view` exposes a
borrowed `TermView`; `internView` is the supported way to intern such a value into a
pool without depending on internal string or term identifiers. When transferring blank
nodes between independent RDF scopes, callers must still choose an explicit relabeling
policy rather than assuming labels establish cross-scope identity.

`validateTriple` and `validateGraphName` expose the common RDF-position checks for
higher-level containers such as stores. `Graph.add` and `Dataset.add` apply those checks
and set semantics. Their `remove` operations delete exact pool-local statements and
preserve the relative order of remaining statements.

`items` and pattern iterators borrow container storage. Any structural mutation can
invalidate a statement slice or iterator, so callers must reacquire them after mutation.
Term views point into stable pool-owned string storage and remain valid until `deinit`.

## RDF line syntaxes

The whole-document line-syntax API is intentionally small:

- `parseNTriples(allocator, input) ParseError!rdf.Graph`
- `parseNQuads(allocator, input) ParseError!rdf.Dataset`
- `serializeNTriplesAlloc(allocator, graph) SerializeError![]u8`
- `serializeNQuadsAlloc(allocator, dataset) SerializeError![]u8`

`ParseError` distinguishes allocation failure, malformed UTF-8, and invalid concrete
syntax. It does not expose lower-level RDF constructor errors. `SerializeError` reports
allocation failure, unknown term identifiers, or blank-node labels that the line
syntaxes cannot represent.

Serializers emit canonical syntax layout and preserve graph or dataset iteration order.
They do not sort statements, relabel blank nodes, or perform RDF graph canonicalization.

Streaming parsers and writers may be added later as separate APIs. Their addition must
not change the ownership or output guarantees of these whole-document functions.

## Turtle

`parseTurtle(allocator, input, options)` implements the RDF 1.1 Turtle grammar.
`TurtleOptions.base_iri` supplies the optional retrieval or containing-document base.
The parser supports `@base`, `@prefix`, `BASE`, and `PREFIX`
directives; relative IRI references; default and named prefixed names; `a`; comments;
labeled blank nodes; all four quoted-string forms; language and datatype suffixes; and
integer, decimal, double, and boolean literals. Predicate lists (`;`), object lists
(`,`), trailing predicate separators, anonymous blank nodes (`[]`), nested blank-node
property lists, and RDF collections expand directly into graph triples. Collections use
the standard `rdf:first`/`rdf:rest` chain and terminate in `rdf:nil`; `()` is `rdf:nil`
itself.

The returned graph owns all parsed terms and follows the same lifetime and error rules
as `parseNTriples`. Parser behavior is checked against all 313 positive syntax, negative
syntax, and evaluation entries in the official RDF 1.1 Turtle manifest.

`serializeTurtleAlloc(allocator, graph)` emits deterministic expanded Turtle using the
N-Triples-compatible subset: one triple per line, absolute IRIs, explicit blank-node
labels, and explicit non-string datatypes. This representation is intentionally stable
and universally parseable; it does not invent prefixes or reconstruct property lists
and collections from their RDF graph expansion.

Output follows graph iteration order. The serializer does not sort statements,
canonicalize blank nodes, or promise byte-identical output for isomorphic graphs built
with different ordering or blank-node identifiers.

## TriG

`parseTriG(allocator, input, options)` implements the RDF 1.1 TriG grammar and returns an
owned dataset. It accepts Turtle statements in the default graph, `{ ... }`
default-graph blocks, `name { ... }` named-graph blocks, and `GRAPH name { ... }`
blocks. Graph names may be IRIs, prefixed names, labeled blank nodes, or anonymous blank
nodes.

Base and prefix declarations are document-level. RDF terms, property lists,
collections, and blank-node identity use the same implementation as Turtle. The API
follows the same ownership and `ParseError` conventions. Parser behavior is checked
against all 357 positive syntax, negative syntax, and evaluation entries in the
official RDF 1.1 TriG manifest.

`serializeTriGAlloc(allocator, dataset)` emits deterministic expanded TriG. Default
graph triples use one N-Triples-compatible statement per line. Every named-graph quad
uses its own `GRAPH name { triple . }` block, including blank-node graph names. This
deliberately favors stable output over grouping adjacent quads or inventing prefixes.

Output follows dataset iteration order. The serializer does not sort quads, relabel
blank nodes, or promise byte-identical output for isomorphic datasets built with
different ordering or blank-node identifiers.

## Indexed store

`store.Store` is an allocator-owned in-memory RDF dataset with its own `TermPool`.
Callers intern terms through `store.terms` and pass those pool-local identifiers to
`add`, `remove`, `contains`, and `iterator`. Insertion applies the shared RDF position
validation and set semantics; it returns false for an already-present quad. Allocation
failure leaves the logical store contents unchanged.

The store indexes subject, predicate, object, and graph name independently. A bound
pattern is driven by the shortest available component posting list and then checked
against all remaining fields. Unbound iteration scans live slots. Both paths return
quads in insertion order without allocating.

Removal uses tombstones so existing slot and posting-list positions remain stable. A
removed quad is absent from queries immediately; reinserting it places it at the end of
the current live iteration order. Any mutation invalidates outstanding store iterators.

`beginTransaction` creates the store's sole active transaction. Transaction changes are
visible immediately to reads, while direct store mutations and nested transactions are
rejected until the transaction closes. `commit` keeps the changes; `rollback` applies
its undo log in reverse without allocating. Deinitializing an active transaction rolls
it back automatically. The transaction must be deinitialized before its store, and a
closed transaction rejects further operations.

`slotCount` reports live plus tombstoned slots and `tombstoneCount` reports reclaimable
slots. `compact` rebuilds slots and all indexes from live quads, preserving their order
and every term identifier. It is rejected during a transaction. Allocation failure
leaves the original store unchanged; successful compaction invalidates iterators.

Expected operation costs, assuming ordinary hash-table behavior, are:

- insertion, exact membership, and removal: amortized O(1), excluding term interning;
- bound iteration: O(k), where k is the shortest selected posting list including stale
  entries not yet compacted;
- unbound iteration: O(s), where s is the current slot count;
- rollback: O(c), where c is the number of effective transaction changes;
- compaction: O(n) time and O(n) temporary storage for n live quads.

## IRI references

`iri.resolveAlloc(allocator, base, reference)` returns an owned absolute IRI using the
RFC 3986 reference-resolution algorithm as applied to IRIs by RFC 3987. The caller frees
the result with the supplied allocator. `ResolveError` distinguishes invalid bases,
invalid references, malformed UTF-8, and allocation failure.

Resolution is not normalization: Unicode text and percent-escape spelling are preserved,
and the function performs no network access.
