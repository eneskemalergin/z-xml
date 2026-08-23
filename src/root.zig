//! A bounded XML reader for Zig.
//!
//! Normal callers use `Reader`. Explicit `...For(config)` aliases expose the
//! specialized reader shapes used by package tools.

const reader = @import("reader.zig");
const dtd_module = @import("dtd.zig");
const encoding = @import("encoding.zig");
const io = @import("io.zig");
const resolver = @import("resolver.zig");
const external_subset = @import("external_subset.zig");
const tree = @import("tree.zig");

/// Compile-time reader configuration.
pub const Config = reader.Config;
/// Reader reset capacity policy.
pub const ResetMode = reader.ResetMode;
/// External-resource handling selected by the normal reader.
pub const ExternalPolicy = reader.NormalExternalPolicy;
/// Continuation selected by a specialized validity callback.
pub const ProfileValidityAction = reader.ValidityAction;
/// Final result from a specialized validating reader.
pub const ProfileValidationStatus = reader.ValidationStatus;
/// XML 1.1 normalization handling selected by the normal reader.
pub const NormalizationPolicy = reader.NormalNormalizationPolicy;
/// Progress or final result from a specialized XML 1.1 reader.
pub const ProfileNormalizationStatus = reader.NormalizationStatus;
/// Reason XML 1.1 full-normalization verification did not succeed.
pub const NormalizationIssueKind = reader.NormalizationIssueKind;
/// Declared DTD attribute type.
pub const AttributeType = dtd_module.AttributeType;
/// Observable lifecycle of a specialized reader.
pub const ProfileLifecycle = reader.Lifecycle;
/// Runtime resource limits.
pub const Limits = reader.Limits;
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
/// Kind reported by a specialized reader for skipped external input.
pub const ProfileSkippedEntityKind = reader.SkippedEntityKind;
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
/// Event production errors from the normal reader.
pub const ReadError = reader.NormalReadError;
/// Reset errors from the normal reader.
pub const ResetError = reader.NormalResetError;
/// Construction errors from the normal reader.
pub const InitError = reader.NormalInitError;
/// Named configurations for supported parser profiles.
pub const Configs = reader.Configs;

/// DTD types used by the normal Reader.
pub const dtd = struct {
    /// Declared attribute type.
    pub const AttributeType = dtd_module.AttributeType;
    /// One validity finding.
    pub const Finding = reader.NormalDtdFinding;
    /// Action returned by a validity finding callback.
    pub const FindingAction = reader.NormalDtdFindingAction;
    /// Synchronous validity finding callback.
    pub const FindingSink = reader.NormalDtdFindingSink;
    /// Immutable compiled declarations shared by validating readers.
    pub const ExternalSubset = external_subset.ExternalSubset;
};

/// Caller-owned input for the normal reader.
pub const Source = reader.NormalSource;
/// Normal reader with runtime policy selection.
pub const Reader = reader.NormalReader;
/// Runtime options for the normal reader.
pub const ReaderOptions = reader.NormalReaderOptions;
/// Namespace handling selected by the normal reader.
pub const NamespacePolicy = reader.NormalNamespacePolicy;
/// DTD handling selected by the normal reader.
pub const DtdPolicy = reader.NormalDtdPolicy;
/// DTD validation options for the normal reader.
pub const DtdValidationOptions = reader.NormalDtdValidationOptions;
/// Stable event returned by the normal reader.
pub const Event = reader.NormalEvent;
/// Stable event payload returned by the normal reader.
pub const EventData = reader.NormalEventData;
/// Original physical byte range in one source.
pub const SourceSpan = reader.NormalSourceSpan;
/// Physical source location with optional line information.
pub const Location = reader.NormalLocation;
/// Fatal reader diagnostic.
pub const Diagnostic = reader.NormalDiagnostic;
/// Synchronous fatal diagnostic callback.
pub const DiagnosticSink = reader.NormalDiagnosticSink;
/// First XML 1.1 normalization finding.
pub const NormalizationFinding = reader.NormalNormalizationFinding;
/// Raw name spelling with optional namespace identity.
pub const Name = reader.NormalName;
/// Resolved namespace identity.
pub const ExpandedName = reader.NormalExpandedName;
/// Attribute borrowed from one start-element event.
pub const Attribute = reader.NormalAttribute;
/// Namespace declaration borrowed from one start-element event.
pub const NamespaceDeclaration = reader.NormalNamespaceDeclaration;
/// XML declaration reported at document start.
pub const XmlDeclaration = reader.NormalXmlDeclaration;
/// Document-start event payload.
pub const DocumentStart = reader.NormalDocumentStart;
/// Document-type event payload.
pub const DocumentType = reader.NormalDocumentType;
/// Start-element event payload.
pub const StartElement = reader.NormalStartElement;
/// End-element event payload.
pub const EndElement = reader.NormalEndElement;
/// Text fragment event payload.
pub const Text = reader.NormalText;
/// Comment fragment event payload.
pub const Comment = reader.NormalComment;
/// Processing-instruction fragment event payload.
pub const ProcessingInstruction = reader.NormalProcessingInstruction;
/// External source omitted by policy.
pub const SkippedExternalSource = reader.NormalSkippedExternalSource;
/// Kind of external source omitted by policy.
pub const SkippedExternalSourceKind = reader.NormalSkippedExternalSourceKind;
/// Final document results.
pub const DocumentEnd = reader.NormalDocumentEnd;
/// Final document-content result.
pub const DocumentContent = reader.NormalDocumentContent;
/// Final DTD validity result.
pub const DtdValidity = reader.NormalDtdValidity;
/// Final XML 1.1 normalization result.
pub const DocumentNormalization = reader.NormalDocumentNormalization;

/// Returns the specialized reader type for a compile-time configuration.
pub const ReaderFor = reader.Reader;
/// Returns the specialized event type for a compile-time configuration.
pub const EventFor = reader.Event;
/// Returns the specialized pull result for a compile-time configuration.
pub const StepFor = reader.Step;
/// Returns the specialized options for a compile-time configuration.
pub const OptionsFor = reader.Options;
/// Returns the specialized location for a compile-time configuration.
pub const LocationFor = reader.Location;
/// Returns the specialized diagnostic for a compile-time configuration.
pub const DiagnosticFor = reader.Diagnostic;
/// Returns the specialized normalization finding for a compile-time configuration.
pub const NormalizationIssueFor = reader.NormalizationIssue;
/// Returns the specialized normalization result for a compile-time configuration.
pub const NormalizationResultFor = reader.NormalizationResult;
/// Returns the specialized validity callback for a compile-time configuration.
pub const ValiditySinkFor = reader.ValiditySink;
/// Returns the specialized name for a compile-time configuration.
pub const NameFor = reader.Name;
/// Returns the specialized attribute for a compile-time configuration.
pub const AttributeFor = reader.Attribute;
/// Event-production error set used by specialized readers.
pub const ProfileReadError = reader.ReadError;
/// Returns a specialized pull reader over one final slice.
pub const ProfileSliceReader = io.SliceReader;
/// Returns a specialized pull adapter over a buffered Zig reader.
pub const ProfileIoReader = io.IoReader;
/// Push callback continuation result for a specialized reader.
pub const ProfileDrainControl = io.DrainControl;
/// Parses one slice through a specialized push callback.
pub const drainProfileSlice = io.drainSlice;
/// Parses one buffered source through a specialized push callback.
pub const drainProfileIo = io.drainIo;
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
