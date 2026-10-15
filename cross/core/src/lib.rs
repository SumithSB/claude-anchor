//! Claude Anchor core for Windows and Linux. The macOS app (Sources/Anchor, Swift) is separate;
//! both share the on-disk contract under ~/.claude-anchor (config.json, routes, usage.json, copied).

pub mod model;
pub mod paths;
pub mod fsx;
pub mod routes;
pub mod creds;
pub mod limits;
pub mod usage;
pub mod sync;
pub mod editor;
pub mod accounts;
pub mod terminal;
pub mod hook;
pub mod exec;
