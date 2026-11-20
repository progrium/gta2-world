//! The sim hosted until workstream A's `sim/` lands: the I1 conformance
//! stub from interfaces/. Same ABI, so swapping is a build flag
//! (`-Dsim=real`), not a code change.
pub const Sim = @import("interfaces").abi.Stub;
