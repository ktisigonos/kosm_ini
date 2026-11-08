//! INI: the `ini` adapter, and `dialect` for programs whose INI differs (D106).

const std = @import("std");

/// Reads and writes `.ini` files, and with `.lang = "ini"` any INI file without that extension
/// (`kdeglobals`, `dunstrc`, qt5ct's colors).
pub const adapter = dialect(.{ .name = "ini", .extensions = &.{".ini"} });

/// The adapter for one program's flavour of INI, for a package to export:
/// `pub const adapter = kosm_ini.dialect(.{ .name = "dunst", .strings = .quoted });`.
pub const dialect = @import("adapter.zig").dialect;

/// Every choice a dialect makes, each with a default.
pub const Dialect = @import("Dialect.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("adapter.zig");
    _ = @import("Parser.zig");
}
