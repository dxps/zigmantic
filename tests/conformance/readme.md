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

The RDF 1.1 model-theory suite is:
`rdf/rdf11/rdf-mt/manifest.ttl`.

- Normative specification: <https://www.w3.org/TR/2014/REC-rdf11-mt-20140225/>
- Published test suite: <https://w3c.github.io/rdf-tests/rdf/rdf11/rdf-mt/>

The RDF 1.1 N-Triples and N-Quads suites are pinned and imported under
`rdf11-ntriples`, `rdf11-nquads`, `rdf11-turtle`, `rdf11-trig`, and `rdf11-mt`.
Each `UPSTREAM.md` records the exact revision and import scope. Imported files retain
the upstream test-suite license and must not be modified to make tests pass.

`zig build test` runs every manifest entry and asserts the expected count, so a refresh
cannot silently omit cases.

The Turtle runner executes positive syntax, negative syntax, and evaluation entries.
Evaluation graphs are compared using blank-node-insensitive RDF graph isomorphism. Its
executable expected-failure mechanism is currently empty; any regression fails the
build, and any future temporary exclusion must be identified by its exact manifest ID.

The TriG runner likewise executes syntax and evaluation entries. Evaluation datasets
are compared by RDF dataset isomorphism, including blank nodes used as graph names. Its
executable expected-failure list is currently empty; all 357 manifest entries pass, and
any regression fails the build.

The model-theory runner executes all 48 active positive and negative entailment entries across
the simple, RDF, and RDFS regimes. Graph-valued conclusions use existential blank-node
matching. A `false` result represents an inconsistent premise, which the current engine
detects for mandatory RDF datatypes and supported explicitly recognized datatypes. The
executable expected-failure list is empty: all 48 active cases pass. Recognized numeric
literals are compared by value, and `rdfD1` generalized literal-type consequences are
matched virtually without weakening the ordinary RDF graph model. Three commented-out,
rescinded or duplicate entries remain in the upstream manifest text but are correctly
excluded from execution.

The runner delegates entailment and consistency decisions to the public library API; it
contains only manifest parsing, fixture loading, expected-result interpretation, and the
executable expected-failure guard.
