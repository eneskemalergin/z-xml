//! A bounded, incremental XML reader for Zig.
//!
//! The public API is specialized by a compile-time configuration. The first
//! implementation stage establishes the type, ownership, lifecycle, and
//! diagnostic contracts before XML grammar support is added.

const reader = @import("reader.zig");
const io = @import("io.zig");

/// Compile-time reader configuration.
pub const Config = reader.Config;
/// Reviewed XML capability profile.
pub const Profile = reader.Profile;
/// DTD capability implied by a profile.
pub const DtdMode = reader.DtdMode;
/// Optional semantic or detailed event reporting.
pub const Report = reader.Report;
/// Diagnostic position precision.
pub const DiagnosticLocation = reader.DiagnosticLocation;
/// Reader reset capacity policy.
pub const ResetMode = reader.ResetMode;
/// Observable reader lifecycle.
pub const Lifecycle = reader.Lifecycle;
/// Runtime resource limits.
pub const Limits = reader.Limits;
/// Reader-owned memory categories.
pub const MemoryUsage = reader.MemoryUsage;
/// Stable diagnostic category.
pub const DiagnosticCode = reader.DiagnosticCode;
/// Input-feed misuse errors.
pub const FeedError = reader.FeedError;
/// Event production errors.
pub const ReadError = reader.ReadError;
/// Reset misuse errors.
pub const ResetError = reader.ResetError;
/// Reader construction errors.
pub const InitError = reader.InitError;
/// Reviewed named configurations.
pub const Configs = reader.Configs;

/// Returns the incremental reader type for a compile-time configuration.
pub const Reader = reader.Reader;
/// Returns the specialized semantic event type.
pub const Event = reader.Event;
/// Returns the specialized pull result type.
pub const Step = reader.Step;
/// Returns the specialized runtime option type.
pub const Options = reader.Options;
/// Returns the specialized source location type.
pub const Location = reader.Location;
/// Returns the specialized diagnostic type.
pub const Diagnostic = reader.Diagnostic;
/// Returns a pull reader over one final slice.
pub const SliceReader = io.SliceReader;
/// Returns a pull adapter over a buffered Zig reader.
pub const IoReader = io.IoReader;
/// Push callback continuation result.
pub const DrainControl = io.DrainControl;
/// Parses one slice through a push callback.
pub const drainSlice = io.drainSlice;
/// Parses one buffered source through a push callback.
pub const drainIo = io.drainIo;
