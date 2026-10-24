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
- `rdf_io.serializeTurtleAlloc` likewise returns an allocator-owned byte slice.
- Term views and statement slices are borrowed and remain valid only while their owner
  remains alive and structurally unchanged.

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

`parseTriG(allocator, input, options)` currently implements the first TriG parser slice
and returns an owned dataset. It accepts Turtle statements in the default graph, `{ ...
}` default-graph blocks, `name { ... }` named-graph blocks, and `GRAPH name { ... }`
blocks. Graph names may be IRIs, prefixed names, or labeled blank nodes.

Base and prefix declarations, RDF terms, property lists, collections, and blank-node
identity use the same implementation and document scope as Turtle. The API follows the
same ownership and `ParseError` conventions. TriG conformance is not yet claimed; the
official manifest remains to be pinned and executed.

## IRI references

`iri.resolveAlloc(allocator, base, reference)` returns an owned absolute IRI using the
RFC 3986 reference-resolution algorithm as applied to IRIs by RFC 3987. The caller frees
the result with the supplied allocator. `ResolveError` distinguishes invalid bases,
invalid references, malformed UTF-8, and allocation failure.

Resolution is not normalization: Unicode text and percent-escape spelling are preserved,
and the function performs no network access.
