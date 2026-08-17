//! A bounded, incremental XML reader for Zig.
//!
//! The public API is specialized by a compile-time configuration. The current
//! implementation provides XML 1.0 UTF-8 no-DTD raw-name and namespace readers.

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
/// Namespace limits omitted from namespace-off options.
pub const NamespaceLimits = reader.NamespaceLimits;
/// Reader-owned memory categories.
pub const MemoryUsage = reader.MemoryUsage;
/// Stable diagnostic category.
pub const DiagnosticCode = reader.DiagnosticCode;
/// Effective XML rules reported at document start.
pub const XmlVersion = reader.XmlVersion;
/// Detected source encoding reported at document start.
pub const SourceEncoding = reader.SourceEncoding;
/// Semantic origin reported by text fragments.
pub const TextOrigin = reader.TextOrigin;
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
/// Returns the specialized element or attribute name type.
pub const Name = reader.Name;
/// Returns the specialized source attribute type.
pub const Attribute = reader.Attribute;
/// Namespace declaration whose slices follow the enclosing event lifetime.
pub const NamespaceDeclaration = reader.NamespaceDeclaration;
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
