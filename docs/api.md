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
- `sparql.parseQuery` returns an allocator-owned `sparql.Query`; its algebra view borrows
  the query and must not outlive it.
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

## SPARQL query foundation

`sparql.Tokenizer` borrows a UTF-8 query string and returns allocation-free tokens with
byte offsets and borrowed lexemes. `sparql.parseQuery(allocator, input)` returns an
owned query syntax tree and reports `InvalidUtf8`, `InvalidSyntax`, or `OutOfMemory`
without exposing partially initialized state.

The initial parser slice implements `SELECT`, optional `DISTINCT` or `REDUCED`, wildcard
or variable projection, optional `WHERE`, and a basic graph pattern whose terms are
variables or IRI references. Unsupported SPARQL grammar is rejected explicitly. Query
variables are stored without their `?` or `$` sigil; IRI-reference terms are stored
without angle brackets.

`BASE` and `PREFIX` declarations precede the query form. `Query.base_iri` and
`Query.prefixDeclarations` expose borrowed query-owned prologue values. Relative IRI
references are resolved when a base is available, and prefixed names are expanded into
their resolved IRIs. The latest repeated declaration supplies a prefix mapping.

`PatternTerm` distinguishes variables, resolved IRIs, blank nodes, and literals.
Labeled blank nodes retain their source identifier; anonymous `[]` nodes use numeric
query-local identities. Literal lexical forms and Unicode escapes are decoded during
parsing. Simple, language-tagged, explicitly typed, integer, decimal, double, and
boolean forms expose their effective datatype IRIs directly. Predicate `a` is stored as
the resolved `rdf:type` IRI.

Predicate lists (`;`) and object lists (`,`) append ordinary `TriplePattern` values.
Blank-node property lists and RDF collections are likewise expanded during parsing;
collections use query-local anonymous nodes plus resolved `rdf:first`, `rdf:rest`, and
`rdf:nil` IRIs. Consequently, `Query.patterns` and `Query.lower` expose the expanded BGP
rather than surface-syntax shorthand.

Compound predicate paths are represented by query-local `PathId` values. `Query.path`
returns the corresponding precedence node, and `Query.negatedPropertySet` returns the
optional borrowed members of a valid negated-set range. Alternatives, sequences,
inverse paths, grouping,
zero-or-more, one-or-more, zero-or-one, and negated property sets are supported. The
lowered BGP carries the complete path and negated-property tables alongside its triples.

SELECT projections may contain plain variables or parenthesized `expression AS
?variable` items. Variable-only projections retain the `Projection.variables` form;
mixed or expression projections use ordered `Projection.items`. `Query.expression` and
`Query.expressionArguments` safely resolve query-local expression IDs and call ranges.

The current expression AST covers RDF terms, variables, unary arithmetic/logical-not,
multiplication/division, addition/subtraction, custom IRI calls, `datatype`, and SPARQL
aggregate call syntax. Aggregate nodes retain DISTINCT, COUNT wildcard, and optional
GROUP_CONCAT separator information. The lowered Project view carries the complete
expression and argument tables.

Expression precedence additionally covers comparison, equality, conditional-and,
conditional-or, and `IN`/`NOT IN` membership. Membership value lists use the same safe
argument-range API as calls.

The lowered BGP exposes ordered `GroupElement` values. Triple elements reference
`TriplePattern` indexes; FILTER elements reference constraint expressions; BIND
elements pair an expression with its introduced variable. `Query.patterns` remains the
direct expanded-triple view for callers that do not yet consume group operations.

`Query.projection` and `Query.patterns` return borrowed slices. `Query.lower` produces
an allocation-free `Project(BGP)` algebra view over the same storage. These views remain
valid only while the query is alive and structurally unchanged. A `Query` must not be
copied after initialization and must be released with `deinit`.

The conformance suite invokes this public parser for all 97 official SPARQL 1.1
query-syntax cases. Its exact expected-failure list is a grammar-coverage baseline, not
an alternate parser or a claim that unsupported positive syntax is conformant.

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

## Entailment materialization

`entailment.entailsGraph(allocator, premise, conclusion, options)` is the stable
conclusion-directed entry point for simple, RDF, and RDFS entailment. It leaves both
graphs unchanged, applies the selected finite closure in an internal materialization,
matches conclusion blank nodes existentially, and returns owned-allocation errors to the
caller. `EntailmentOptions` selects the regime and explicitly recognized datatype
profile.

Conclusion blank-node mappings may be non-injective, must remain consistent across all
conclusion triples, and are explored with backtracking when an earlier candidate blocks
a later match. As required by simple entailment, this search is potentially exponential
in adversarial conclusions. Allocation failure during graph copying, closure, or mapping
is returned without leaking memory or modifying either input graph.

`entailment.isGraphConsistent` applies the same regime and datatype semantics without a
conclusion graph. Simple graphs are always consistent. Under RDF and RDFS, an
inconsistent premise entails every conclusion through `entailsGraph`.

`entailment.Materialization` owns one RDF term pool and an indexed union of asserted and
inferred triples. `fromGraph` copies an asserted graph into that independent ownership
scope. `addAsserted` and `addInferred` keep set semantics; when an inferred triple is
later asserted, its provenance is promoted without changing union iteration order.

`iterator(.asserted)`, `iterator(.inferred)`, and `iterator(.all)` expose deterministic,
allocation-free views of the two provenance partitions or their union. The materialized
union is intentionally separate from the input graph: inference never silently mutates
the caller's assertions.

This API is infrastructure for forward rule application. By itself it does not claim
that RDF or RDFS closure has been reached; conformance belongs to the rule sets layered
on top of it.

`materializeRdfCore` atomically adds the eight fixed RDF axiomatic triples that do not
use container-membership properties and applies entailment pattern `rdfD2`, inferring
that every predicate occurring in the union is an `rdf:Property`. It returns the number
of newly inferred triples and is idempotent.

`materializeRdfContainerMembership` adds the target-aware RDF property axioms for the
otherwise infinite `rdf:_n` family. The public `entailsGraph` composition invokes it for
plain RDF entailment, including when a membership IRI occurs only in the conclusion.

`materializeRdfsContainerMembership` accepts the requested conclusion graph so the
otherwise infinite `rdf:_n` axiom family can be instantiated finitely. It discovers
valid membership-property IRIs in both the materialization and conclusion vocabulary,
adds their RDF/RDFS type, domain, range, and `rdfs:subPropertyOf rdfs:member` facts, and
propagates matching membership assertions through `rdfs:member`. If neither graph names
one, it uses `rdf:_1` as the closure witness required by RDF 1.1 Semantics. The update is
atomic and idempotent. Datatype pattern `rdfD1` and general RDFS closure remain separate,
so this API alone does not claim complete RDFS entailment.

`materializeRdfsCore` adds all finite non-container RDFS axiomatic triples, recognizes
the mandatory `rdf:langString` and `xsd:string` datatype IRIs for `rdfs1`, and applies
`rdfs1` through `rdfs13` repeatedly to a fixed point. Call it after `materializeRdfCore`
and, for conclusion-directed closure, `materializeRdfsContainerMembership`. It emits
only ordinary RDF triples: generalized intermediate triples requiring literal subjects
or non-IRI predicates are not represented by the current RDF data model. Datatype value
interpretation and inconsistency detection remain separate layers.

`DatatypeProfile` explicitly selects supported optional datatype IRIs. The mandatory
`xsd:string` and `rdf:langString` datatypes are always active;
`isMandatoryDatatypeConsistent` is the empty-profile convenience call.
`isDatatypeConsistent` additionally validates enabled `xsd:integer` and `xsd:int`
lexical spaces and bounds, performs their value-space membership checks, and detects
incompatible RDFS ranges. Initial `rdf:XMLLiteral` support safely detects incomplete or
structurally impossible markup but is not yet a complete XML 1.0 parser. Optional
datatypes are never silently treated as recognized.

`recognizedLiteralValuesEqual` compares two supported, well-typed literals by datatype
value. Integer and decimal values use allocation-free canonical decimal comparison, so
lexical forms such as `+0010` and `10.0` compare equal when their datatypes are
recognized. Float and double values use their IEEE-754 widths, including rounding,
infinities, NaN, and distinct positive and negative zero. A `null` result means at least
one datatype is not recognized; it does not mean the values differ.

`recognizedLiteralBelongsTo` exposes the corresponding value-space membership test for
a recognized datatype IRI. It returns `null` for unknown datatype semantics. This lets
entailment checking implement `rdfD1` existential conclusions without inserting a
generalized triple whose literal subject would violate the ordinary RDF graph API.

## IRI references

`iri.resolveAlloc(allocator, base, reference)` returns an owned absolute IRI using the
RFC 3986 reference-resolution algorithm as applied to IRIs by RFC 3987. The caller frees
the result with the supplied allocator. `ResolveError` distinguishes invalid bases,
invalid references, malformed UTF-8, and allocation failure.

Resolution is not normalization: Unicode text and percent-escape spelling are preserved,
and the function performs no network access.
