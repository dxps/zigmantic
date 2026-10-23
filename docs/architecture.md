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
