# SPARQL 1.1 Query coverage

This audit compares the public `sparql` module with the normative grammar in the
[SPARQL 1.1 Query Language Recommendation](https://www.w3.org/TR/sparql11-query/#grammar).
It covers query productions; SPARQL Update is milestone 8.

Passing the pinned 97-case W3C query-syntax manifest is a regression baseline, not a
claim that every grammar production or its evaluation semantics is implemented.

## Query forms and modifiers

| Grammar area | Status | Remaining work |
| --- | --- | --- |
| Prologue and dataset clauses | Implemented | Retain coverage while adding query forms. |
| SELECT and subqueries | Partial | Add remaining graph patterns, expressions, and evaluation. |
| ASK | Syntax foundation | Add evaluation and result production. |
| CONSTRUCT | Partial | Add explicit construct templates; restrict and represent the `CONSTRUCT WHERE` template correctly. |
| DESCRIBE | Missing | Add targets, optional WHERE, lowering, and result semantics. |
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
| Triple blocks and graph-node shorthand | Implemented | Add broader differential and fuzz coverage. |
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
NOT EXISTS, all seven aggregate spellings, and the core term/numeric built-ins are
represented with function-specific signatures. Production 121 remains incomplete:
date/time, hash, UUID, and conditional built-ins still need syntax validation. All
built-ins still require evaluation semantics.

## Data and lexical grammar

IRI and prefixed-name expansion, variables, blank nodes, RDF literals, numeric and
boolean forms, collections, property lists, VALUES cells, and UNDEF are implemented.
The existing syntax manifest and local negative tests cover the accepted boundary, but
the terminal productions should receive a dedicated differential/fuzz audit before a
full parser-conformance claim.

## Algebra and execution

Current lowering is a borrowed structural view, not the complete SPARQL algebra from
section 18. Evaluation is not implemented. Remaining execution work includes:

1. solution mappings and expression errors;
2. BGP matching over the indexed store;
3. join, left join, union, minus, filter, extend, and table operators;
4. grouping, aggregates, having, ordering, projection, distinct/reduced, slicing, and
   trailing VALUES ordering;
5. dataset and named-graph selection, subqueries, property paths, and query-form result
   construction;
6. SELECT/ASK result serialization and RDF results for CONSTRUCT/DESCRIBE.

## Conformance expansion

- Keep the 97/97 syntax manifest as a no-exclusion gate.
- Add local normative-production tests for features absent from that manifest.
- Activate the applicable W3C SPARQL query evaluation, property-path, aggregates,
  functions, CSV/TSV, and result-format manifests as their execution layers land.
- Record unsupported, disputed, or environment-dependent SERVICE cases explicitly.

## Planned implementation order

1. Complete built-in expression syntax and arity validation.
2. Add DESCRIBE and explicit CONSTRUCT templates.
3. Freeze the first evaluation-ready AST/algebra boundary, then implement solution
   mappings and BGP evaluation over the indexed store.

