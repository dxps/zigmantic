# Architecture

## Ownership and RDF terms

Zigmantic uses explicit allocator ownership. A `TermPool` owns every byte of every RDF
term interned into it and releases that memory in `deinit`. `TermId` values are compact
indices into exactly one pool and must not be passed to a graph or dataset backed by a
different pool.

The internal RDF 1.1 literal representation always contains a lexical form and datatype
IRI. A simple literal receives `xsd:string`. A language-tagged string receives
`rdf:langString`, and its language tag is normalized to ASCII lowercase for RDF term
equality. Lexical forms are not value-normalized: for example, distinct lexical forms of
the same numeric value remain distinct RDF terms.

`TermPool.view` returns borrowed slices. They remain valid until the owning pool is
deinitialized. Public APIs do not transfer ownership implicitly.

`TermId` equality is meaningful only within one pool. `TermPool.eqlTerm` and
`TermPool.hashTerm` operate on RDF term values and therefore provide the explicit path
for comparison and hashing across pools. Hashes are deterministic and do not expose
the internal string or term indices.

## Graph and dataset semantics

`Graph` and `Dataset` each own a term pool and statement storage. Their `add` operations
enforce RDF position constraints and set semantics:

- a subject is an IRI or blank node;
- a predicate is an IRI;
- an object is any RDF term;
- a graph name is an IRI or blank node;
- inserting an existing triple or quad is a successful no-op.

Storage is intentionally linear during the data-model milestone. Indexed statement
storage belongs to the later store milestone and can replace these containers without
changing RDF term ownership or equality.

Graphs and datasets provide allocation-free pattern iterators. A null pattern field is
a wildcard; a non-null field requires exact pool-local identifier equality. Dataset
graph patterns distinguish the default graph from a named graph.

## Validation boundaries

Programmatic constructors reject malformed UTF-8 and structurally invalid identifiers.
Concrete syntax parsers will additionally enforce the complete grammar and escaping
rules of their specifications. Parser conformance claims will be based on official test
suites, not on constructor validation alone.

## Parsing ownership and errors

Whole-document parsing APIs return an owned graph and clean up partial state on error.
Malformed concrete syntax is reported as `InvalidSyntax`; malformed UTF-8 remains
`InvalidUtf8`, and allocation failures remain `OutOfMemory`. This keeps syntax errors
independent of lower-level term-constructor validation details.

The stable whole-document line-syntax surface and its ownership rules are recorded in
`docs/api.md`. Serializers preserve statement iteration order but do not perform graph
canonicalization or blank-node relabeling.

## IRI resolution

IRI reference resolution is a standalone `iri` module because Turtle, TriG, SPARQL, and
other syntaxes share the same operation. It implements the RFC 3986 section 5.2 merge and
dot-segment algorithm, applied directly to Unicode IRI references as specified by RFC
3987 section 6.5. Resolution preserves Unicode and percent-escape spelling and performs
no dereferencing or optional normalization.

The incremental Turtle parser keeps base and prefix mappings as parser-owned state and
uses the shared `iri` module for every relative IRI. Its lexer establishes the token
boundary that Turtle and TriG can share as their grammars are completed. Parser state is
temporary; only fully interned RDF terms survive in the returned graph.

Turtle predicate and object lists are expanded while parsing and do not require an
intermediate syntax tree. Empty `[]` forms allocate fresh blank nodes. Generated labels
are tracked separately from source labels so an explicit label can never alias an
anonymous node, including when its spelling matches the internal generation pattern.
Non-empty property lists reuse the same predicate/object expansion routine recursively;
their generated blank node is returned to the enclosing subject or object position.
Collections are expanded during parsing into fresh blank-node cells connected by
`rdf:first` and `rdf:rest`. Empty collections and the final rest link use the interned
`rdf:nil` IRI. Collection items recurse through the normal object parser, so nested
collections and property lists share the same ownership and identity rules.

Turtle serialization uses an expanded representation shared with the canonical-layout
N-Triples writer. This is a valid Turtle subset and avoids heuristic reconstruction of
prefix declarations, property lists, or collections from graph structure. The output is
deterministic for a graph's iteration order and blank-node identifiers, but it is not an
RDF graph canonicalization algorithm.

Turtle and TriG share a `StatementTarget` abstraction over graphs and dataset graph
selections. The lexer, directives, RDF term grammar, lists, collections, and blank-node
scope remain single implementations; only statement routing differs. This keeps term
identifiers in the final owner from the start and avoids copying between temporary
graphs and datasets.
