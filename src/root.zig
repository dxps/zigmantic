//! Zigmantic is a pure Zig semantic-web toolkit.

pub const rdf = @import("rdf.zig");
pub const rdf_io = @import("rdf_io.zig");

test {
    _ = rdf;
    _ = rdf_io;
}
