//! A bounded, incremental XML reader for Zig.
//!
//! The public API is specialized by a compile-time configuration. The library
//! provides XML 1.0 no-DTD, non-validating, and DTD-validating readers
//! with raw-name and namespace-aware profiles.

const reader = @import("reader.zig");
const encoding = @import("encoding.zig");
const io = @import("io.zig");
const resolver = @import("resolver.zig");
const external_subset = @import("external_subset.zig");
const tree = @import("tree.zig");

/// Compile-time reader configuration.
pub const Config = reader.Config;
/// XML capability profile.
pub const Profile = reader.Profile;
/// DTD capability implied by a profile.
pub const DtdMode = reader.DtdMode;
/// Optional semantic or detailed event reporting.
pub const Report = reader.Report;
/// Diagnostic position precision.
pub const DiagnosticLocation = reader.DiagnosticLocation;
/// Reader reset capacity policy.
pub const ResetMode = reader.ResetMode;
/// Runtime policy for external declarations.
pub const ExternalPolicy = reader.ExternalPolicy;
/// Continuation selected by a validity diagnostic callback.
pub const ValidityAction = reader.ValidityAction;
/// Final validating-reader result.
pub const ValidationStatus = reader.ValidationStatus;
/// Declared DTD attribute type.
pub const AttributeType = @import("dtd.zig").AttributeType;
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
/// Caller-owned incremental source transcoder.
pub const Transcoder = encoding.Transcoder;
/// One bounded caller-transcoder result.
pub const TranscodeStep = encoding.TranscodeStep;
/// Invalid caller-transcoder result error.
pub const TranscoderError = encoding.TranscoderError;
/// Caller-controlled external entity resolver.
pub const Resolver = resolver.Resolver;
/// External entity resolver request.
pub const ResolverRequest = resolver.Request;
/// External entity resolver result.
pub const ResolverResult = resolver.Result;
/// Successfully acquired external byte stream.
pub const ResolverSource = resolver.Source;
/// External source stream read result.
pub const ResolverReadResult = resolver.ReadResult;
/// Kind of external entity requested.
pub const ExternalEntityKind = resolver.EntityKind;
/// Kind reported for external input intentionally skipped by policy.
pub const SkippedEntityKind = reader.SkippedEntityKind;
/// Optional handle-relative filesystem resolver with no network behavior.
pub const RootedFilesystemResolver = resolver.RootedFilesystem;
/// Immutable compiled declarations shared by validating readers.
pub const ExternalSubset = external_subset.ExternalSubset;
/// Construction options for a compiled external subset.
pub const ExternalSubsetOptions = external_subset.Options;
/// Synchronous provider used while compiling nested external declarations.
pub const ExternalSubsetProvider = external_subset.Provider;
/// Errors returned while compiling external declarations.
pub const ExternalSubsetProviderError = external_subset.ProviderError;
/// External declaration request made during subset compilation.
pub const ExternalSubsetRequest = external_subset.Request;
/// External declaration result returned during subset compilation.
pub const ExternalSubsetResult = external_subset.Result;
/// External declaration bytes returned during subset compilation.
pub const ExternalSubsetContent = external_subset.Content;
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
/// Named configurations for supported parser profiles.
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
/// Returns the specialized validity diagnostic callback type.
pub const ValiditySink = reader.ValiditySink;
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
/// Immutable owned-tree node index with zero as the null sentinel.
pub const NodeIndex = tree.NodeIndex;
/// Immutable owned-tree node kind.
pub const NodeKind = tree.NodeKind;
/// Independent limits for owned-tree construction.
pub const TreeLimits = tree.Limits;
/// Optional initial owned-tree capacities.
pub const TreeCapacityHints = tree.CapacityHints;
/// Runtime owned-tree construction options.
pub const TreeOptions = tree.Options;
/// Errors specific to owned-tree construction.
pub const TreeBuildError = tree.BuildError;
/// Owned-tree capacity accounting.
pub const TreeMemoryUsage = tree.MemoryUsage;
/// Name whose slices borrow from an owned document.
pub const TreeName = tree.Name;
/// Attribute whose slices borrow from an owned document.
pub const TreeAttribute = tree.Attribute;
/// Namespace declaration whose slices borrow from an owned document.
pub const TreeNamespaceDeclaration = tree.NamespaceDeclaration;
/// XML declaration retained by an owned document.
pub const TreeDeclaration = tree.Declaration;
/// Document type header retained by an owned document.
pub const TreeDocumentType = tree.DocumentType;
/// Kind of source-ordered DTD report retained by an owned document.
pub const TreeDtdRecordKind = tree.DtdRecordKind;
/// Source-ordered DTD report retained by an owned document.
pub const TreeDtdRecord = tree.DtdRecord;
/// Returns the immutable owned document type for a reader configuration.
pub const Document = tree.Document;
/// Returns the allocation-free child iterator for an owned document configuration.
pub const TreeChildIterator = tree.ChildIterator;
/// Returns the public-event tree builder for a reader configuration.
pub const TreeBuilder = tree.Builder;
/// Builds an owned document from a compatible public pull reader.
pub const buildTreeFromPull = tree.buildFromPull;
