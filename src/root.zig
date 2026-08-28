//! Public facade for bounded XML reading, owned documents, and streaming UTF-8 writing.
//!
//! The normal surface selects parser, document, and output policy at run time.
//! Streaming event slices expire when the next read begins, owned documents retain
//! copied data until deinitialization, and writers borrow their sinks without
//! flushing or deinitializing them. Initialized readers, documents, and writers own
//! memory that their caller must release; inputs, callback contexts, and sinks remain
//! caller-owned.
//!
//! Names containing `Profile` or ending in `For` expose compile-time specialized
//! shapes. Values derived from one `Config` must be used with that same configuration.

const reader = @import("reader.zig");
const dtd_module = @import("dtd.zig");
const encoding = @import("encoding.zig");
const io = @import("io.zig");
const resolver = @import("resolver.zig");
const external_subset = @import("external_subset.zig");
const tree = @import("tree.zig");
const writer = @import("writer.zig");

pub const Config = reader.Config;
pub const ResetMode = reader.ResetMode;
pub const ExternalPolicy = reader.NormalExternalPolicy;
pub const ProfileValidityAction = reader.ValidityAction;
pub const ProfileValidationStatus = reader.ValidationStatus;
pub const NormalizationPolicy = reader.NormalNormalizationPolicy;
pub const ProfileNormalizationStatus = reader.NormalizationStatus;
pub const NormalizationIssueKind = reader.NormalizationIssueKind;
pub const ProfileLifecycle = reader.Lifecycle;
pub const Limits = reader.NormalLimits;
pub const MemoryUsage = reader.MemoryUsage;
pub const DiagnosticCode = reader.DiagnosticCode;
pub const XmlVersion = reader.XmlVersion;
pub const SourceEncoding = reader.SourceEncoding;
pub const Transcoder = encoding.Transcoder;
pub const TranscodeStep = encoding.TranscodeStep;
pub const TranscoderError = encoding.TranscoderError;
pub const Resolver = resolver.Resolver;
pub const ResolverRequest = resolver.Request;
pub const ResolverResult = resolver.Result;
pub const ResolverSource = resolver.Source;
pub const ResolverReadResult = resolver.ReadResult;
pub const ExternalEntityKind = resolver.EntityKind;
pub const ProfileSkippedEntityKind = reader.SkippedEntityKind;
pub const RootedFilesystemResolver = resolver.RootedFilesystem;
pub const TextOrigin = reader.TextOrigin;
pub const ReadError = reader.NormalReadError;
pub const ResetError = reader.NormalResetError;
pub const InitError = reader.NormalInitError;
pub const Configs = reader.Configs;

pub const dtd = struct {
    pub const AttributeType = dtd_module.AttributeType;
    pub const Finding = reader.NormalDtdFinding;
    pub const FindingAction = reader.NormalDtdFindingAction;
    pub const FindingSink = reader.NormalDtdFindingSink;
    pub const ExternalSubset = external_subset.ExternalSubset;
    pub const ExternalSubsetOptions = external_subset.Options;
    pub const ExternalSubsetProvider = external_subset.Provider;
    pub const ExternalSubsetProviderError = external_subset.ProviderError;
    pub const ExternalSubsetRequest = external_subset.Request;
    pub const ExternalSubsetResult = external_subset.Result;
    pub const ExternalSubsetContent = external_subset.Content;
};

pub const Source = reader.NormalSource;
pub const Reader = reader.NormalReader;
pub const ReaderOptions = reader.NormalReaderOptions;
pub const NamespacePolicy = reader.NormalNamespacePolicy;
pub const DtdPolicy = reader.NormalDtdPolicy;
pub const DtdValidationOptions = reader.NormalDtdValidationOptions;
pub const Event = reader.NormalEvent;
pub const EventData = reader.NormalEventData;
pub const SourceSpan = reader.NormalSourceSpan;
pub const Location = reader.NormalLocation;
pub const Diagnostic = reader.NormalDiagnostic;
pub const DiagnosticSink = reader.NormalDiagnosticSink;
pub const NormalizationFinding = reader.NormalNormalizationFinding;
pub const Name = reader.NormalName;
pub const ExpandedName = reader.NormalExpandedName;
pub const Attribute = reader.NormalAttribute;
pub const NamespaceDeclaration = reader.NormalNamespaceDeclaration;
pub const XmlDeclaration = reader.NormalXmlDeclaration;
pub const DocumentStart = reader.NormalDocumentStart;
pub const DocumentType = reader.NormalDocumentType;
pub const StartElement = reader.NormalStartElement;
pub const EndElement = reader.NormalEndElement;
pub const Text = reader.NormalText;
pub const Comment = reader.NormalComment;
pub const ProcessingInstruction = reader.NormalProcessingInstruction;
pub const SkippedExternalSource = reader.NormalSkippedExternalSource;
pub const SkippedExternalSourceKind = reader.NormalSkippedExternalSourceKind;
pub const DocumentEnd = reader.NormalDocumentEnd;
pub const DocumentContent = reader.NormalDocumentContent;
pub const DtdValidity = reader.NormalDtdValidity;
pub const DocumentNormalization = reader.NormalDocumentNormalization;

pub const ReaderFor = reader.Reader;
pub const EventFor = reader.Event;
pub const StepFor = reader.Step;
pub const OptionsFor = reader.Options;
pub const LocationFor = reader.Location;
pub const DiagnosticFor = reader.Diagnostic;
pub const NormalizationIssueFor = reader.NormalizationIssue;
pub const NormalizationResultFor = reader.NormalizationResult;
pub const ValiditySinkFor = reader.ValiditySink;
pub const NameFor = reader.Name;
pub const AttributeFor = reader.Attribute;
pub const ProfileReadError = reader.ReadError;
pub const ProfileSliceReader = io.SliceReader;
pub const ProfileIoReader = io.IoReader;
pub const ProfileDrainControl = io.DrainControl;
pub const drainProfileSlice = io.drainSlice;
pub const drainProfileIo = io.drainIo;
pub const Node = tree.NodeIndex;
pub const NodeKind = tree.NodeKind;
pub const DocumentLimits = tree.DocumentLimits;
pub const DocumentOptions = tree.DocumentOptions;
pub const DocumentMemoryUsage = tree.DocumentMemoryUsage;
pub const DocumentNamespaceDeclaration = tree.NamespaceDeclaration;
pub const ParseDocumentError = tree.ParseDocumentError;
pub const Document = tree.Document;
pub const parseDocument = tree.parseDocument;
pub const Writer = writer.Writer;
pub const WriterOptions = writer.WriterOptions;
pub const WriterLimits = writer.WriterLimits;
pub const WriterMemoryUsage = writer.WriterMemoryUsage;
pub const WriterInitError = writer.WriterInitError;
pub const WriterError = writer.WriterError;

pub const ProfileTreeOptions = tree.Options;
pub const ProfileTreeDtdRecordKind = tree.DtdRecordKind;
pub const ProfileDocumentFor = tree.ProfileDocumentFor;
pub const ProfileTreeBuilderFor = tree.ProfileBuilderFor;
pub const buildProfileTreeFromPull = tree.buildProfileFromPull;
