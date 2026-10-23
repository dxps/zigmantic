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

The RDF 1.1 N-Triples and N-Quads suites are pinned and imported under
`rdf11-ntriples` and `rdf11-nquads`. Each `UPSTREAM.md` records the exact revision and
import scope. Imported files retain the upstream test-suite license and must not be
modified to make tests pass.

`zig build test` runs every manifest entry and asserts the expected count, so a refresh
cannot silently omit cases.
