//! Keeps compile-time XML profiles available to package tests and layout probes.
//!
//! The package does not export this module. `api` is the same root facade exposed
//! as `z_xml`; the remaining declarations expose fixed Reader and Document shapes
//! used only by development checks.

const reader = @import("reader.zig");
const io = @import("io.zig");
const tree = @import("tree.zig");

pub const api = @import("root.zig");

pub const Config = reader.Config;
pub const Configs = reader.Configs;
pub const ProfileValidityAction = reader.ValidityAction;
pub const ProfileValidationStatus = reader.ValidationStatus;
pub const ProfileNormalizationStatus = reader.NormalizationStatus;
pub const ProfileLifecycle = reader.Lifecycle;
pub const ProfileSkippedEntityKind = reader.SkippedEntityKind;
pub const ReaderFor = reader.Reader;
pub const EventFor = reader.Event;
pub const StepFor = reader.Step;
pub const OptionsFor = reader.Options;
pub const LocationFor = reader.Location;
pub const DiagnosticFor = reader.Diagnostic;
pub const NormalizationResultFor = reader.NormalizationResult;
pub const ValiditySinkFor = reader.ValiditySink;
pub const NameFor = reader.Name;
pub const AttributeFor = reader.Attribute;
pub const ProfileSliceReader = io.SliceReader;
pub const ProfileIoReader = io.IoReader;
pub const ProfileDrainControl = io.DrainControl;
pub const drainProfileSlice = io.drainSlice;
pub const ProfileTreeOptions = tree.Options;
pub const ProfileTreeDtdRecordKind = tree.DtdRecordKind;
pub const ProfileDocumentFor = tree.ProfileDocumentFor;
pub const ProfileTreeBuilderFor = tree.ProfileBuilderFor;
pub const buildProfileTreeFromPull = tree.buildProfileFromPull;
