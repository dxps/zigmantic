//! Zigmantic is a pure Zig semantic-web toolkit.

pub const iri = @import("iri.zig");
pub const rdf = @import("rdf.zig");
pub const rdf_io = @import("rdf_io.zig");
pub const store = @import("store.zig");
pub const entailment = @import("entailment.zig");
pub const sparql = @import("sparql.zig");

test {
    _ = iri;
    _ = rdf;
    _ = rdf_io;
    _ = store;
    _ = entailment;
    _ = sparql;
}
