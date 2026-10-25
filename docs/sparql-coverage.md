# SPARQL 1.1 Query coverage

This audit compares the public `sparql` module with the normative grammar in the
[SPARQL 1.1 Query Language Recommendation](https://www.w3.org/TR/sparql11-query/#grammar).
It covers query productions; SPARQL Update is milestone 8.

The pinned 97-case W3C query-syntax manifest remains the repository regression gate.
A broader differential audit against the pinned upstream corpus also parses all 598
SPARQL 1.0/1.1 query-evaluation inputs and all 210 positive syntax inputs while
rejecting all 91 negative syntax inputs. Evaluation semantics are not yet implemented.

## Query forms and modifiers

| Grammar area | Status | Remaining work |
| --- | --- | --- |
| Prologue and dataset clauses | Syntax implemented | Add dataset evaluation. |
| SELECT and subqueries | Syntax implemented | Add algebra translation and evaluation. |
| ASK | Syntax foundation | Add evaluation and result production. |
| CONSTRUCT | Syntax foundation | Add template instantiation and RDF graph results. |
| DESCRIBE | Syntax foundation | Define resource-description and result semantics. |
| GROUP BY | Syntax implemented | Add grouping and alias evaluation. |
| HAVING | Syntax foundation | Add constraint evaluation after grouping. |
| ORDER BY | Syntax foundation | Add SPARQL ordering and expression-error semantics. |
| LIMIT and OFFSET | Syntax implemented | Add slicing after ordering and projection. |
| Trailing VALUES | Implemented | Add evaluation as a join before projection expressions. |

These rows correspond primarily to productions 2 and 7–28. Solution-modifier syntax is
represented for the current expression slice across SELECT, CONSTRUCT, ASK, and
subqueries.

## Graph patterns

| Grammar area | Status | Remaining work |
| --- | --- | --- |
| Triple blocks and graph-node shorthand | Syntax implemented | Add fuzz coverage and evaluation. |
| Property paths | Syntax implemented | Add path evaluation. |
| Nested groups, UNION, OPTIONAL, and MINUS | Syntax implemented | Add algebra translation and evaluation. |
| FILTER, BIND, EXISTS, and NOT EXISTS | Syntax foundation | Complete expression coverage and evaluation. |
| Inline VALUES | Implemented | Add table-join evaluation. |
| Subqueries | Syntax foundation | Add projection boundaries and evaluation. |
| GRAPH | Syntax foundation | Add named-dataset evaluation. |
| SERVICE and SERVICE SILENT | Syntax foundation | Add a pluggable remote-execution interface and evaluation. |

This area maps to productions 53–72. `SERVICE` must not acquire implicit networking;
evaluation will require a caller-supplied service interface.

## Expressions

Operator precedence, RDF terms, variables, custom IRI calls, `IN`/`NOT IN`, EXISTS,
NOT EXISTS, all seven aggregate spellings, and every built-in call in production 121
are represented with function-specific signatures. Aggregate projection scope is
validated for explicit and implicit groups. Built-in evaluation semantics are not yet
implemented.

## Data and lexical grammar

IRI and prefixed-name expansion, variables, blank nodes, RDF literals, numeric and
boolean forms, collections, property lists, VALUES cells, and UNDEF are implemented.
The repository syntax manifest, local negative tests, and broader upstream differential
audit cover the accepted boundary. A full parser-conformance claim still requires the
corpus to become a durable automated gate plus dedicated fuzzing.

## Algebra and execution

Current lowering is a borrowed structural view, not the complete SPARQL algebra from
section 18. The first evaluation layer provides owned solution mappings and evaluates
ordinary triple BGPs against the indexed store's default graph with bag semantics.
An expression context now owns a separate result term pool, preserves semantic faults as
values, and implements variables, constants, numeric arithmetic and promotion, RDF value
comparisons, membership, SPARQL logical error propagation, BOUND, logical negation, and
effective boolean value. Core RDF-term, language, datatype, type-test, IRI, and numeric
scalar built-ins are implemented; string/regex, constructors, temporal, hashing,
conditional, and nondeterministic calls remain.
Remaining execution work includes:

1. remaining scalar built-in evaluation;
2. join, left join, union, minus, filter, extend, and table operators;
3. grouping, aggregates, having, ordering, projection, distinct/reduced, slicing, and
   trailing VALUES ordering;
4. dataset and named-graph selection, subqueries, property paths, and query-form result
   construction;
5. SELECT/ASK result serialization and RDF results for CONSTRUCT/DESCRIBE.

## Conformance expansion

- Keep the 97/97 syntax manifest as a no-exclusion gate.
- Add local normative-production tests for features absent from that manifest.
- Activate the applicable W3C SPARQL query evaluation, property-path, aggregates,
  functions, CSV/TSV, and result-format manifests as their execution layers land.
- Record unsupported, disputed, or environment-dependent SERVICE cases explicitly.

## Planned implementation order

1. Implement string, regex, and RDF literal-constructor built-ins over the expression
   runtime.
2. Promote the broader parser audit into a durable conformance gate while evaluation
   manifests are activated incrementally.

