# Public API conventions

## Ownership

- `rdf.Graph`, `rdf.Dataset`, and `rdf.TermPool` own their allocations and require
  `deinit` with the same allocator lifetime used at construction.
- `rdf_io.parseNTriples` returns an owned `rdf.Graph`.
- `rdf_io.parseNQuads` returns an owned `rdf.Dataset`.
- `rdf_io.serializeNTriplesAlloc` and `rdf_io.serializeNQuadsAlloc` return owned byte
  slices that the caller frees with the allocator passed to the function.
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

## IRI references

`iri.resolveAlloc(allocator, base, reference)` returns an owned absolute IRI using the
RFC 3986 reference-resolution algorithm as applied to IRIs by RFC 3987. The caller frees
the result with the supplied allocator. `ResolveError` distinguishes invalid bases,
invalid references, malformed UTF-8, and allocation failure.

Resolution is not normalization: Unicode text and percent-escape spelling are preserved,
and the function performs no network access.
