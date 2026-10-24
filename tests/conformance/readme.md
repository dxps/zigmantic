# RDF conformance suites

Zigmantic targets the W3C RDF test manifests maintained in
<https://github.com/w3c/rdf-tests>.

The first suite is RDF 1.1 N-Triples:
`rdf/rdf11/rdf-n-triples/manifest.ttl`.

- Normative specification: <https://www.w3.org/TR/2014/REC-n-triples-20140225/>
- Published test suite: <https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-n-triples/>

The next suite is RDF 1.1 N-Quads:
`rdf/rdf11/rdf-n-quads/manifest.ttl`.

- Normative specification: <https://www.w3.org/TR/2014/REC-n-quads-20140225/>
- Published test suite: <https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-n-quads/>

The RDF 1.1 Turtle suite is:
`rdf/rdf11/rdf-turtle/manifest.ttl`.

- Normative specification: <https://www.w3.org/TR/2014/REC-turtle-20140225/>
- Published test suite: <https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-turtle/>

The RDF 1.1 TriG suite is:
`rdf/rdf11/rdf-trig/manifest.ttl`.

- Normative specification: <https://www.w3.org/TR/2014/REC-trig-20140225/>
- Published test suite: <https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-trig/>

The RDF 1.1 N-Triples and N-Quads suites are pinned and imported under
`rdf11-ntriples`, `rdf11-nquads`, `rdf11-turtle`, and `rdf11-trig`. Each `UPSTREAM.md`
records the exact revision and import scope. Imported files retain the upstream
test-suite license and must not be modified to make tests pass.

`zig build test` runs every manifest entry and asserts the expected count, so a refresh
cannot silently omit cases.

The Turtle runner executes positive syntax, negative syntax, and evaluation entries.
Evaluation graphs are compared using blank-node-insensitive RDF graph isomorphism. Its
executable expected-failure mechanism is currently empty; any regression fails the
build, and any future temporary exclusion must be identified by its exact manifest ID.

The TriG runner likewise executes syntax and evaluation entries. Evaluation datasets
are compared by RDF dataset isomorphism, including blank nodes used as graph names. Its
expected-failure list is an executable implementation-gap baseline: an unlisted failure
or a listed case that starts passing both fail the build until reviewed.
