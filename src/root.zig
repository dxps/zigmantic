//! Zigmantic is a pure Zig semantic-web toolkit.

pub const iri = @import("iri.zig");
pub const rdf = @import("rdf.zig");
pub const rdf_io = @import("rdf_io.zig");
pub const store = @import("store.zig");

test {
    _ = iri;
    _ = rdf;
    _ = rdf_io;
    _ = store;
}
