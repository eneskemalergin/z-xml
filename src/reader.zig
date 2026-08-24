//! Incremental XML parsing and the normal Reader API.

const std = @import("std");
const encoding_module = @import("encoding.zig");
const dtd_module = @import("dtd.zig");
const resolver_module = @import("resolver.zig");
const validation_module = @import("validation.zig");
const external_subset_module = @import("external_subset.zig");
const unicode_normalization = @import("unicode_normalization.zig");

/// XML capability profile selected at compile time.
pub const Profile = enum {
    xml10_utf8_no_dtd,
    xml10_utf8_ns_no_dtd,
    xml10_no_dtd,
    xml10_ns_no_dtd,
    xml11_no_dtd,
    xml11_ns_no_dtd,
    xml10_nonvalidating,
    xml10_ns_nonvalidating,
    xml10_dtd_validating,
    xml10_ns_dtd_validating,
    xml11_nonvalidating,
    xml11_ns_nonvalidating,
    xml11_dtd_validating,
    xml11_ns_dtd_validating,

    /// Returns whether namespace processing is required by this profile.
    pub fn hasNamespaces(comptime self: Profile) bool {
        return switch (self) {
            .xml10_utf8_ns_no_dtd,
            .xml10_ns_no_dtd,
            .xml11_ns_no_dtd,
            .xml10_ns_nonvalidating,
            .xml10_ns_dtd_validating,
            .xml11_ns_nonvalidating,
            .xml11_ns_dtd_validating,
            => true,
            else => false,
        };
    }

    /// Returns the DTD processing mode required by this profile.
    pub fn dtdMode(comptime self: Profile) DtdMode {
        return switch (self) {
            .xml10_utf8_no_dtd,
            .xml10_utf8_ns_no_dtd,
            .xml10_no_dtd,
            .xml10_ns_no_dtd,
            .xml11_no_dtd,
            .xml11_ns_no_dtd,
            => .rejected,
            .xml10_nonvalidating,
            .xml10_ns_nonvalidating,
            .xml11_nonvalidating,
            .xml11_ns_nonvalidating,
            => .nonvalidating,
            .xml10_dtd_validating,
            .xml10_ns_dtd_validating,
            .xml11_dtd_validating,
            .xml11_ns_dtd_validating,
            => .validating,
        };
    }

    /// Returns whether the profile includes XML 1.1 behavior.
    pub fn isXml11(comptime self: Profile) bool {
        return switch (self) {
            .xml11_no_dtd,
            .xml11_ns_no_dtd,
            .xml11_nonvalidating,
            .xml11_ns_nonvalidating,
            .xml11_dtd_validating,
            .xml11_ns_dtd_validating,
            => true,
            else => false,
        };
    }

    /// Returns whether the profile is the UTF-8-only core subset.
    pub fn isUtf8Only(comptime self: Profile) bool {
        return switch (self) {
            .xml10_utf8_no_dtd, .xml10_utf8_ns_no_dtd => true,
            else => false,
        };
    }
};

/// DTD capability implied by a profile.
pub const DtdMode = enum {
    rejected,
    nonvalidating,
    validating,
};

/// Optional event detail selected at compile time.
pub const Report = enum {
    semantic,
    detailed,
};

/// Diagnostic location detail selected at compile time.
pub const DiagnosticLocation = enum {
    byte_offset,
    line_column,
};

/// Compile-time reader configuration.
pub const Config = struct {
    profile: Profile,
    report: Report = .semantic,
    diagnostic_location: DiagnosticLocation = .line_column,
    event_locations: bool = false,
    /// Includes caller-controlled external parsed-entity resolution.
    external_sources: bool = false,

    /// Rejects combinations whose promised events cannot exist in a profile.
    pub fn validate(comptime self: Config) void {
        if (self.report == .detailed and self.profile.dtdMode() == .rejected) {
            @compileError("detailed reporting requires a DTD-capable profile");
        }
        if (self.external_sources and self.profile.dtdMode() == .rejected) {
            @compileError("external sources require a DTD-capable profile");
        }
    }
};

/// Named configurations for specialized parser users and package tools.
pub const Configs = struct {
    /// Line-aware XML 1.0 UTF-8 core profile.
    pub const XML10_UTF8_NO_DTD: Config = .{
        .profile = .xml10_utf8_no_dtd,
    };
    /// Byte-offset-only XML 1.0 UTF-8 performance profile.
    pub const XML10_UTF8_NO_DTD_FAST: Config = .{
        .profile = .xml10_utf8_no_dtd,
        .diagnostic_location = .byte_offset,
    };
    /// XML 1.0 UTF-8 core profile with line-aware event spans.
    pub const XML10_UTF8_NO_DTD_LOCATED: Config = .{
        .profile = .xml10_utf8_no_dtd,
        .event_locations = true,
    };
    /// Namespace-aware XML 1.0 UTF-8 core profile.
    pub const XML10_UTF8_NAMESPACES_NO_DTD: Config = .{
        .profile = .xml10_utf8_ns_no_dtd,
    };
    /// Byte-offset-only namespace-aware XML 1.0 UTF-8 performance profile.
    pub const XML10_UTF8_NAMESPACES_NO_DTD_FAST: Config = .{
        .profile = .xml10_utf8_ns_no_dtd,
        .diagnostic_location = .byte_offset,
    };
    /// Line-aware XML 1.0 UTF-8 and UTF-16 no-DTD profile.
    pub const XML10_NO_DTD: Config = .{
        .profile = .xml10_no_dtd,
    };
    /// Byte-offset-only XML 1.0 UTF-8 and UTF-16 no-DTD profile.
    pub const XML10_NO_DTD_FAST: Config = .{
        .profile = .xml10_no_dtd,
        .diagnostic_location = .byte_offset,
    };
    /// Namespace-aware XML 1.0 UTF-8 and UTF-16 no-DTD profile.
    pub const XML10_NAMESPACES_NO_DTD: Config = .{
        .profile = .xml10_ns_no_dtd,
    };
    /// Byte-offset-only namespace-aware UTF-8 and UTF-16 no-DTD profile.
    pub const XML10_NAMESPACES_NO_DTD_FAST: Config = .{
        .profile = .xml10_ns_no_dtd,
        .diagnostic_location = .byte_offset,
    };
    /// Full non-validating XML 1.0 profile without namespaces.
    pub const XML10_NONVALIDATING: Config = .{
        .profile = .xml10_nonvalidating,
        .external_sources = true,
    };
    /// Full namespace-aware non-validating XML 1.0 profile.
    pub const XML10_NAMESPACES_NONVALIDATING: Config = .{
        .profile = .xml10_ns_nonvalidating,
        .external_sources = true,
    };
    /// Non-validating XML 1.0 restricted to the document and internal subset.
    pub const XML10_NONVALIDATING_INTERNAL: Config = .{
        .profile = .xml10_nonvalidating,
    };
    /// Namespace-aware non-validating XML 1.0 restricted to internal sources.
    pub const XML10_NAMESPACES_NONVALIDATING_INTERNAL: Config = .{
        .profile = .xml10_ns_nonvalidating,
    };
    /// DTD-validating XML 1.0 profile without namespaces.
    pub const XML10_VALIDATING: Config = .{
        .profile = .xml10_dtd_validating,
        .external_sources = true,
    };
    /// Namespace-aware DTD-validating XML 1.0 profile.
    pub const XML10_NAMESPACES_VALIDATING: Config = .{
        .profile = .xml10_ns_dtd_validating,
        .external_sources = true,
    };
    /// Detailed namespace-aware DTD-validating XML 1.0 profile.
    pub const XML10_NAMESPACES_VALIDATING_DETAILED: Config = .{
        .profile = .xml10_ns_dtd_validating,
        .report = .detailed,
        .event_locations = true,
        .external_sources = true,
    };
    /// Namespace-aware DTD-validating XML 1.1 profile.
    pub const XML11_NAMESPACES_VALIDATING: Config = .{
        .profile = .xml11_ns_dtd_validating,
        .external_sources = true,
    };
    /// Full non-validating XML 1.1 profile without namespaces.
    pub const XML11_NONVALIDATING: Config = .{
        .profile = .xml11_nonvalidating,
        .external_sources = true,
    };
    /// Full namespace-aware non-validating XML 1.1 profile.
    pub const XML11_NAMESPACES_NONVALIDATING: Config = .{
        .profile = .xml11_ns_nonvalidating,
        .external_sources = true,
    };
    /// DTD-validating XML 1.1 profile without namespaces.
    pub const XML11_VALIDATING: Config = .{
        .profile = .xml11_dtd_validating,
        .external_sources = true,
    };
};

/// Reader reset policy.
pub const ResetMode = enum {
    retain_capacity,
    release_memory,
};

/// Observable reader lifecycle.
pub const Lifecycle = enum {
    ready,
    producing,
    needs_input,
    failed,
    done,
    deinitialized,
};

/// Runtime limits enforced by the reader.
pub const Limits = struct {
    /// Finite default limits for specialized readers.
    pub const general: Limits = .{};

    /// Maximum simultaneously open element count.
    max_depth: usize = 256,
    /// Maximum cumulative raw-name bytes for open elements.
    max_open_name_bytes: usize = 1024 * 1024,
    /// Maximum bytes accepted in one unfinished token.
    max_partial_token_bytes: usize = 64 * 1024,
    /// Maximum source attributes accepted on one element.
    max_attributes_per_element: usize = 256,
    /// Maximum raw bytes accepted in one attribute name.
    max_attribute_name_bytes: usize = 64 * 1024,
    /// Maximum semantic bytes accepted in one attribute value.
    max_attribute_value_bytes: usize = 1024 * 1024,
    /// Maximum aggregate name and value bytes accepted on one element.
    max_attribute_bytes_per_element: usize = 1024 * 1024,
    /// Maximum source bytes accepted in one complete start tag.
    max_start_tag_bytes: usize = 1024 * 1024,
    /// Maximum bytes exposed by one fragmented semantic event.
    max_fragment_bytes: usize = 64 * 1024,
    /// Maximum UTF-8 bytes accepted in one processing-instruction target.
    max_processing_instruction_target_bytes: usize = 64 * 1024,
    /// Maximum owned capacity retained across a retain reset.
    max_retained_bytes: usize = 1024 * 1024,

    fn validate(self: Limits) bool {
        return self.max_depth > 0 and
            self.max_open_name_bytes > 0 and
            self.max_partial_token_bytes > 0 and
            self.max_attributes_per_element > 0 and
            self.max_attribute_name_bytes > 0 and
            self.max_attribute_value_bytes > 0 and
            self.max_attribute_bytes_per_element > 0 and
            self.max_start_tag_bytes > 0 and
            self.max_fragment_bytes > 0 and
            self.max_processing_instruction_target_bytes > 0;
    }
};

/// Namespace limits specialized out of namespace-off reader options.
pub fn NamespaceLimits(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            /// Maximum namespace declarations accepted on one element.
            max_declarations_per_element: usize = 64,
            /// Maximum active namespace bindings, including shadowed bindings.
            max_active_bindings: usize = 1024,
            /// Maximum bytes retained by active namespace bindings.
            max_binding_bytes: usize = 1024 * 1024,
            /// Maximum UTF-8 bytes accepted in one qualified name.
            max_qname_bytes: usize = 64 * 1024,
            /// Maximum weighted prefix and expanded-name comparison work per start element.
            max_comparison_work: usize = 1024 * 1024,

            fn validate(self: @This()) bool {
                return self.max_declarations_per_element > 0 and
                    self.max_active_bindings > 0 and
                    self.max_binding_bytes > 0 and
                    self.max_qname_bytes > 0 and
                    self.max_comparison_work > 0;
            }
        }
    else
        struct {
            fn validate(_: @This()) bool {
                return true;
            }
        };
}

/// Runtime resource limits exposed by the normal reader.
pub const NormalLimits = struct {
    /// Finite default limits for the normal reader.
    pub const general: NormalLimits = .{};

    /// Maximum simultaneously open element count.
    max_depth: usize = 256,
    /// Maximum cumulative raw-name bytes for open elements.
    max_open_name_bytes: usize = 1024 * 1024,
    /// Maximum bytes accepted in one unfinished token.
    max_partial_token_bytes: usize = 64 * 1024,
    /// Maximum source attributes accepted on one element.
    max_attributes_per_element: usize = 256,
    /// Maximum raw bytes accepted in one attribute name.
    max_attribute_name_bytes: usize = 64 * 1024,
    /// Maximum semantic bytes accepted in one attribute value.
    max_attribute_value_bytes: usize = 1024 * 1024,
    /// Maximum aggregate name and value bytes accepted on one element.
    max_attribute_bytes_per_element: usize = 1024 * 1024,
    /// Maximum source bytes accepted in one complete start tag.
    max_start_tag_bytes: usize = 1024 * 1024,
    /// Maximum bytes exposed by one fragmented semantic event.
    max_fragment_bytes: usize = 64 * 1024,
    /// Maximum UTF-8 bytes accepted in one processing-instruction target.
    max_processing_instruction_target_bytes: usize = 64 * 1024,
    /// Maximum namespace declarations accepted on one element.
    max_namespace_declarations_per_element: usize = 64,
    /// Maximum active namespace bindings, including shadowed bindings.
    max_active_namespace_bindings: usize = 1024,
    /// Maximum prefix and URI bytes retained by active namespace bindings.
    max_namespace_binding_bytes: usize = 1024 * 1024,
    /// Maximum UTF-8 bytes accepted in one qualified name.
    max_qname_bytes: usize = 64 * 1024,
    /// Maximum weighted namespace comparison work per start element.
    max_namespace_comparison_work: usize = 1024 * 1024,
    /// Maximum decoded bytes in one document type declaration.
    max_dtd_bytes: usize = 1024 * 1024,
    /// Maximum markup declarations processed from DTD subsets and parameter entities.
    max_dtd_declarations: usize = 4096,
    /// Maximum cumulative decoded bytes in DTD markup declarations.
    max_dtd_declaration_bytes: usize = 1024 * 1024,
    /// Maximum retained DTD element declarations.
    max_dtd_element_declarations: usize = 1024,
    /// Maximum retained DTD attribute declarations.
    max_dtd_attribute_declarations: usize = 4096,
    /// Maximum retained general and parameter entity declarations.
    max_dtd_entity_declarations: usize = 1024,
    /// Maximum retained DTD notation declarations.
    max_dtd_notation_declarations: usize = 1024,
    /// Maximum nested DTD content-model group depth.
    max_dtd_group_depth: usize = 256,
    /// Maximum cumulative DTD content-model and attribute-type grammar nodes.
    max_dtd_grammar_nodes: usize = 64 * 1024,
    /// Maximum cumulative normalized DTD replacement and default bytes.
    max_dtd_entity_replacement_bytes: usize = 1024 * 1024,
    /// Maximum active parameter or general entity depth.
    max_dtd_entity_depth: usize = 64,
    /// Maximum cumulative parameter and general entity reference count.
    max_dtd_entity_references: usize = 1024 * 1024,
    /// Maximum cumulative bytes included from entity replacement text.
    max_dtd_expanded_bytes: usize = 8 * 1024 * 1024,
    /// Maximum expanded bytes per entity-reference source byte after the minimum threshold.
    max_dtd_expansion_ratio: usize = 100,
    /// Expanded-byte count at or below which ratio enforcement remains disabled.
    dtd_expansion_ratio_minimum_bytes: usize = 4096,
    /// Maximum cumulative weighted DTD name-comparison work.
    max_dtd_comparison_work: usize = 8 * 1024 * 1024,
    /// Maximum positions compiled for one DTD element content model.
    max_validation_content_positions: usize = 4096,
    /// Maximum states compiled across DTD element content models.
    max_validation_content_states: usize = 16 * 1024,
    /// Maximum transitions compiled across DTD element content models.
    max_validation_content_transitions: usize = 64 * 1024,
    /// Maximum cumulative DTD content-model compilation work.
    max_validation_compilation_work: usize = 8 * 1024 * 1024,
    /// Maximum IDs retained for DTD validity checks.
    max_validation_ids: usize = 1024 * 1024,
    /// Maximum IDREF values retained for DTD validity checks.
    max_validation_idrefs: usize = 1024 * 1024,
    /// Maximum cumulative bytes retained for IDs and IDREF values.
    max_validation_identity_bytes: usize = 8 * 1024 * 1024,
    /// Maximum cumulative DTD validity comparison work.
    max_validation_comparison_work: usize = 16 * 1024 * 1024,
    /// Maximum DTD validity findings reported for one document.
    max_validation_findings: usize = 1024,
    /// Maximum external resources acquired for one document.
    max_external_resources: usize = 256,
    /// Maximum bytes read from one external resource.
    max_external_source_bytes: usize = 8 * 1024 * 1024,
    /// Maximum cumulative bytes read from external resources.
    max_external_total_bytes: usize = 32 * 1024 * 1024,
    /// Maximum bytes accepted in one external source identifier.
    max_external_identifier_bytes: usize = 64 * 1024,
    /// Maximum owned capacity retained across a retain reset.
    max_retained_bytes: usize = 1024 * 1024,

    fn validate(self: NormalLimits) bool {
        return normalParserLimits(self).validate() and
            normalDtdLimits(self).validate() and
            normalValidationLimits(self).validate() and
            self.max_namespace_declarations_per_element > 0 and
            self.max_active_namespace_bindings > 0 and
            self.max_namespace_binding_bytes > 0 and
            self.max_qname_bytes > 0 and
            self.max_namespace_comparison_work > 0 and
            self.max_external_resources > 0 and
            self.max_external_source_bytes > 0 and
            self.max_external_total_bytes > 0 and
            self.max_external_identifier_bytes > 0;
    }
};

/// Categories of memory owned by a reader.
pub const MemoryUsage = struct {
    /// Number of active open-element frames.
    parser_stack_len: usize = 0,
    /// Open-element frame capacity measured in frame slots.
    parser_stack_capacity: usize = 0,
    /// Active raw-name bytes owned by open frames and an unfinished start tag.
    open_name_bytes: usize = 0,
    /// Raw-name arena capacity measured in bytes.
    open_name_capacity: usize = 0,
    /// Source attributes retained for the current start element.
    attribute_count: usize = 0,
    /// Reusable source-attribute record capacity measured in slots.
    attribute_record_capacity: usize = 0,
    /// Reusable public-attribute capacity measured in slots.
    attribute_event_capacity: usize = 0,
    /// Active attribute name and value bytes.
    attribute_bytes: usize = 0,
    /// Active reusable scratch bytes, including attributes and markup targets.
    scratch_bytes: usize = 0,
    /// Reusable attribute and markup scratch capacity measured in bytes.
    scratch_capacity: usize = 0,
    /// Reusable decoded UTF-8 bytes and source-width metadata.
    decoder_capacity: usize = 0,
    /// Namespace storage capacity measured in bytes.
    namespace_capacity: usize = 0,
    /// Active namespace bindings, including shadowed bindings.
    namespace_binding_count: usize = 0,
    /// Active bytes retained by namespace bindings.
    namespace_bytes: usize = 0,
    /// DTD storage capacity measured in bytes.
    dtd_capacity: usize = 0,
    /// Retained notation-record storage measured in bytes.
    notation_capacity: usize = 0,
    /// Validation storage capacity measured in bytes.
    validation_capacity: usize = 0,
    /// Retained compiled content-model storage measured in bytes.
    content_model_capacity: usize = 0,
    /// Retained ID and IDREF storage measured in bytes.
    identity_capacity: usize = 0,
    /// IDs retained for uniqueness and reference checks.
    id_count: usize = 0,
    /// IDREF values retained for document-end resolution.
    idref_count: usize = 0,
    /// Active bytes retained for ID and IDREF values.
    identity_bytes: usize = 0,
    /// Retained ID-record storage measured in bytes.
    id_capacity: usize = 0,
    /// Retained IDREF-record storage measured in bytes.
    idref_capacity: usize = 0,
    /// Retained ID lookup-index storage measured in bytes.
    id_index_capacity: usize = 0,
    /// Total reader-owned reusable capacity measured in bytes.
    retained_capacity: usize = 0,
};

/// Stable diagnostic category returned by the reader.
pub const DiagnosticCode = enum {
    dtd_forbidden,
    external_resource_forbidden,
    out_of_memory,
    empty_document,
    unexpected_document_text,
    malformed_start_tag,
    malformed_attribute,
    attribute_less_than,
    duplicate_attribute,
    malformed_end_tag,
    unexpected_end_tag,
    mismatched_end_tag,
    unclosed_element,
    incomplete_input,
    multiple_document_elements,
    trailing_content,
    depth_limit,
    open_name_limit,
    partial_token_limit,
    attribute_count_limit,
    attribute_name_limit,
    attribute_value_limit,
    attribute_bytes_limit,
    start_tag_limit,
    fragment_limit,
    malformed_utf8,
    malformed_encoding,
    missing_encoding_signature,
    encoding_mismatch,
    forbidden_character,
    malformed_reference,
    invalid_character_reference,
    undeclared_entity,
    cdata_close_in_text,
    malformed_declaration,
    incomplete_declaration,
    unsupported_version,
    unsupported_encoding,
    not_fully_normalized,
    normalization_properties_unknown,
    misplaced_xml_declaration,
    reserved_processing_instruction_target,
    malformed_processing_instruction,
    incomplete_processing_instruction,
    processing_instruction_target_limit,
    malformed_qname,
    malformed_ncname,
    illegal_namespace_declaration,
    reserved_namespace_name,
    unbound_prefix,
    duplicate_expanded_attribute,
    namespace_declaration_limit,
    namespace_binding_limit,
    namespace_binding_bytes_limit,
    qname_limit,
    namespace_comparison_limit,
    malformed_comment,
    unclosed_comment,
    malformed_cdata,
    unclosed_cdata,
    malformed_markup_declaration,
    misplaced_doctype,
    malformed_doctype,
    external_subset_mismatch,
    malformed_dtd,
    malformed_element_declaration,
    malformed_attribute_list_declaration,
    malformed_entity_declaration,
    malformed_notation_declaration,
    undeclared_parameter_entity,
    recursive_parameter_entity,
    dtd_bytes_limit,
    dtd_declaration_limit,
    dtd_declaration_bytes_limit,
    dtd_element_declaration_limit,
    dtd_attribute_declaration_limit,
    dtd_entity_declaration_limit,
    dtd_notation_declaration_limit,
    dtd_grammar_depth_limit,
    dtd_grammar_node_limit,
    dtd_replacement_bytes_limit,
    entity_depth_limit,
    entity_reference_limit,
    entity_expansion_ratio_limit,
    dtd_comparison_work_limit,
    validation_content_position_limit,
    validation_content_state_limit,
    validation_content_transition_limit,
    validation_compilation_work_limit,
    validation_id_limit,
    validation_idref_limit,
    validation_identity_bytes_limit,
    validation_comparison_work_limit,
    recursive_entity,
    entity_expansion_limit,
    external_resource_count_limit,
    external_resource_bytes_limit,
    external_resource_identifier_limit,
    external_resource_depth_limit,
    resolver_not_found,
    resolver_forbidden,
    resolver_unsupported_scheme,
    resolver_io_failure,
    resolver_resource_limit,
    resolver_cancelled,
    resolver_invalid_result,
    transcoder_cancelled,
    dtd_finding_cancelled,
    read_failed,
    validity_missing_doctype,
    validity_root_name_mismatch,
    validity_undeclared_element,
    validity_duplicate_element_declaration,
    validity_nondeterministic_content_model,
    validity_parameter_entity_nesting,
    validity_duplicate_mixed_content_name,
    validity_element_content,
    validity_undeclared_attribute,
    validity_undeclared_entity,
    validity_required_attribute,
    validity_fixed_attribute,
    validity_attribute_value,
    validity_duplicate_id,
    validity_unresolved_idref,
    validity_multiple_id_attributes,
    validity_id_default,
    validity_multiple_notation_attributes,
    validity_notation_on_empty_element,
    validity_duplicate_enumeration_token,
    validity_undeclared_notation,
    validity_duplicate_notation,
    validity_xml_space_declaration,
    validity_standalone_external_default,
    validity_standalone_external_normalization,
    validity_standalone_external_whitespace,
};

/// Location containing the precision selected by `config`.
pub fn Location(comptime config: Config) type {
    config.validate();
    return if (config.diagnostic_location == .line_column)
        struct {
            source_id: u32 = 0,
            byte_offset: u64 = 0,
            line: u64 = 1,
            byte_column: u64 = 1,
        }
    else
        struct {
            source_id: u32 = 0,
            byte_offset: u64 = 0,
        };
}

/// Diagnostic type specialized to the selected location precision.
pub fn Diagnostic(comptime config: Config) type {
    return struct {
        code: DiagnosticCode,
        primary: Location(config),
        related: ?Location(config) = null,
        inclusion_trace: if (config.external_sources) []const Location(config) else void =
            if (config.external_sources) &.{} else {},
    };
}

fn ResolverOptions(comptime config: Config) type {
    return if (!config.external_sources)
        struct {}
    else
        struct {
            /// Whether external declarations are skipped or passed to `resolver`.
            policy: ExternalPolicy = .skip,
            /// Caller-owned resolver. Required when `policy` is `resolve`.
            resolver: ?resolver_module.Resolver = null,
            /// Base identifier of the document entity, when known.
            document_base_id: ?[]const u8 = null,
            /// Maximum external resources acquired for one document.
            max_resources: usize = 256,
            /// Maximum bytes read from one external resource.
            max_source_bytes: usize = 8 * 1024 * 1024,
            /// Maximum cumulative bytes read from external resources.
            max_total_bytes: usize = 32 * 1024 * 1024,
            /// Maximum bytes accepted in one external source identifier.
            max_identifier_bytes: usize = 64 * 1024,

            fn validate(self: @This()) bool {
                return self.max_resources > 0 and self.max_source_bytes > 0 and
                    self.max_total_bytes > 0 and self.max_identifier_bytes > 0 and
                    (self.policy == .skip or self.resolver != null);
            }
        };
}

/// Runtime handling of external declarations in non-validating profiles.
pub const ExternalPolicy = enum {
    skip,
    resolve,
};

/// Continuation selected by a validity diagnostic sink.
pub const ValidityAction = enum { continue_validation, cancel };

/// Final state reported by a validating reader.
pub const ValidationStatus = enum { valid, invalid, incomplete };

/// Runtime policy for XML 1.1 full-normalization verification.
pub const NormalizationPolicy = enum {
    /// Skip verification only when the caller certifies the input.
    unchecked,
    /// Continue parsing and expose the final verification result.
    report,
    /// Stop at the first definite or indeterminate finding.
    require,
};

/// Progress or final result of XML 1.1 full-normalization verification.
pub const NormalizationStatus = enum {
    /// Verification was not requested or the document selected XML 1.0 rules.
    unchecked,
    /// Verification is active and the document is not complete.
    checking,
    /// Every read parsed entity and relevant construct passed verification.
    normalized,
    /// A definite full-normalization violation was found.
    not_normalized,
    /// The input used a character newer than the available property tables.
    indeterminate,
};

/// Reason that XML 1.1 full-normalization verification did not succeed.
pub const NormalizationIssueKind = enum {
    not_nfc,
    composing_start,
    unknown_character,
};

/// First XML 1.1 full-normalization finding and its associated source location.
pub fn NormalizationIssue(comptime config: Config) type {
    return struct {
        kind: NormalizationIssueKind,
        location: Location(config),
    };
}

/// XML 1.1 full-normalization result specialized out of XML 1.0 readers.
pub fn NormalizationResult(comptime config: Config) type {
    return if (config.profile.isXml11())
        struct {
            status: NormalizationStatus,
            issue: ?NormalizationIssue(config),
        }
    else
        struct {};
}

/// Synchronous validity diagnostic callback specialized to the reader.
pub fn ValiditySink(comptime config: Config) type {
    return struct {
        context: ?*anyopaque,
        reportFn: *const fn (?*anyopaque, Diagnostic(config)) ValidityAction,

        pub fn report(self: @This(), value: Diagnostic(config)) ValidityAction {
            return self.reportFn(self.context, value);
        }
    };
}

fn ValidationOptions(comptime config: Config) type {
    return if (config.profile.dtdMode() == .validating)
        struct {
            collect_validity_errors: bool = false,
            limits: validation_module.Limits = .{},
            sink: ?ValiditySink(config) = null,
            external_subset: ?*const external_subset_module.ExternalSubset = null,
        }
    else
        struct {};
}

fn NormalizationOptions(comptime config: Config) type {
    return if (config.profile.isXml11()) NormalizationPolicy else void;
}

/// Runtime options containing only state permitted by `config`.
pub fn Options(comptime config: Config) type {
    config.validate();
    return if (config.external_sources) struct {
        limits: Limits = .{},
        namespace_limits: NamespaceLimits(config) = .{},
        dtd_limits: if (config.profile.dtdMode() == .rejected) struct {} else dtd_module.Limits = .{},
        resolver: ResolverOptions(config) = .{},
        validation: ValidationOptions(config) = .{},
        /// XML 1.1 full-normalization verification policy.
        normalization: NormalizationOptions(config) = if (config.profile.isXml11()) .report else {},
    } else struct {
        limits: Limits = .{},
        namespace_limits: NamespaceLimits(config) = .{},
        dtd_limits: if (config.profile.dtdMode() == .rejected) struct {} else dtd_module.Limits = .{},
        validation: ValidationOptions(config) = .{},
        /// XML 1.1 full-normalization verification policy.
        normalization: NormalizationOptions(config) = if (config.profile.isXml11()) .report else {},
    };
}

const RawName = struct {
    raw: []const u8,
};

const ExpandedName = struct {
    raw: []const u8,
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
};

/// Element or attribute name specialized to the selected namespace profile.
pub fn Name(comptime config: Config) type {
    return if (config.profile.hasNamespaces()) ExpandedName else RawName;
}

/// Source attribute whose slices follow the enclosing event lifetime.
pub fn Attribute(comptime config: Config) type {
    return if (config.profile.dtdMode() == .rejected)
        struct {
            name: Name(config),
            value: []const u8,
        }
    else
        struct {
            name: Name(config),
            value: []const u8,
            specified: bool,
            declared_type: ?dtd_module.AttributeType,
        };
}

/// One source-ordered namespace declaration whose slices follow the event lifetime.
pub const NamespaceDeclaration = struct {
    prefix: ?[]const u8,
    namespace_uri: []const u8,
};

fn StartElement(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            name: Name(config),
            attributes: []const Attribute(config),
            namespace_declarations: []const NamespaceDeclaration,
            empty_element_syntax: bool,
        }
    else
        struct {
            name: Name(config),
            attributes: []const Attribute(config),
            empty_element_syntax: bool,
        };
}

fn EndElement(comptime config: Config) type {
    return struct {
        name: Name(config),
    };
}

/// XML rules selected for a document entity.
pub const XmlVersion = dtd_module.XmlVersion;

/// Source encoding detected for the document entity.
pub const SourceEncoding = encoding_module.SourceEncoding;

/// Origin of one text fragment.
pub const TextOrigin = enum {
    character_data,
    cdata,
};

const DocumentStart = struct {
    effective_version: XmlVersion = .xml10,
    declared_version: ?[]const u8 = null,
    source_encoding: SourceEncoding = .utf8,
    declared_encoding: ?[]const u8 = null,
    standalone: bool = false,
    standalone_declared: bool = false,
};
fn DocumentEnd(comptime config: Config) type {
    return if (config.profile.dtdMode() == .validating)
        struct { validation: ValidationStatus }
    else
        struct {};
}
const DocumentType = struct {
    root_name: []const u8,
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
};
fn Text(comptime config: Config) type {
    return if (config.profile.dtdMode() == .validating)
        struct {
            bytes: []const u8,
            origin: TextOrigin = .character_data,
            ignorable_whitespace: bool = false,
        }
    else
        struct {
            bytes: []const u8,
            origin: TextOrigin = .character_data,
        };
}
const Comment = struct {
    bytes: []const u8,
    complete: bool,
};
const ProcessingInstruction = struct {
    target: []const u8,
    data: []const u8,
    complete: bool,
};
const Declaration = struct {
    name: []const u8,
};
/// Kind of external input intentionally not read by the selected policy.
pub const SkippedEntityKind = enum { external_subset, parameter_entity, general_entity };

fn SkippedEntity(comptime config: Config) type {
    return struct {
        name: ?[]const u8,
        kind: SkippedEntityKind,
        public_id: ?[]const u8,
        system_id: ?[]const u8,
        reference: Location(config),
    };
}
const NotationDeclaration = struct {
    name: []const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
};
const UnparsedEntityDeclaration = struct {
    name: []const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
    notation_name: []const u8,
};
const EntityBoundary = struct {
    name: []const u8,
};

fn NoDtdEventPayload(comptime config: Config) type {
    return union(enum) {
        document_start: DocumentStart,
        start_element: StartElement(config),
        end_element: EndElement(config),
        text: Text(config),
        comment: Comment,
        processing_instruction: ProcessingInstruction,
        document_end: DocumentEnd(config),
    };
}

fn DtdEventPayload(comptime config: Config) type {
    return union(enum) {
        document_start: DocumentStart,
        document_type: DocumentType,
        notation_declaration: NotationDeclaration,
        unparsed_entity_declaration: UnparsedEntityDeclaration,
        start_element: StartElement(config),
        end_element: EndElement(config),
        text: Text(config),
        comment: Comment,
        processing_instruction: ProcessingInstruction,
        skipped_entity: SkippedEntity(config),
        document_end: DocumentEnd(config),
    };
}

fn DetailedDtdEventPayload(comptime config: Config) type {
    return union(enum) {
        document_start: DocumentStart,
        document_type: DocumentType,
        notation_declaration: NotationDeclaration,
        unparsed_entity_declaration: UnparsedEntityDeclaration,
        element_declaration: Declaration,
        attribute_list_declaration: Declaration,
        parsed_entity_declaration: Declaration,
        entity_start: EntityBoundary,
        entity_end: EntityBoundary,
        start_element: StartElement(config),
        end_element: EndElement(config),
        text: Text(config),
        comment: Comment,
        processing_instruction: ProcessingInstruction,
        skipped_entity: SkippedEntity(config),
        document_end: DocumentEnd(config),
    };
}

fn EventPayload(comptime config: Config) type {
    config.validate();
    if (config.profile.dtdMode() == .rejected) return NoDtdEventPayload(config);
    if (config.report == .detailed) return DetailedDtdEventPayload(config);
    return DtdEventPayload(config);
}

fn Span(comptime config: Config) type {
    return struct {
        start: Location(config),
        end: Location(config),
    };
}

/// Semantic event type with impossible tags removed at compile time.
pub fn Event(comptime config: Config) type {
    config.validate();
    return if (config.event_locations)
        struct {
            payload: EventPayload(config),
            span: Span(config),
        }
    else
        EventPayload(config);
}

/// Pull-reader result.
pub fn Step(comptime config: Config) type {
    return union(enum) {
        event: Event(config),
        need_input,
        done,
    };
}

/// Errors reported while constructing a reader.
pub const InitError = error{
    InvalidOptions,
};

/// Errors reported while installing an input chunk.
pub const FeedError = error{
    InvalidState,
};

/// Errors reported while producing an event.
pub const ReadError = error{
    InvalidXml,
    InvalidDtd,
    NotValid,
    UnsupportedFeature,
    LimitExceeded,
    ResolverFailed,
    ReadFailed,
    Cancelled,
    NotNormalized,
    OutOfMemory,
    InvalidState,
};

/// Errors reported while resetting a reader.
pub const ResetError = error{
    InvalidState,
};

/// Caller-owned input that remains valid until a successful reset or deinitialization.
pub const NormalSource = union(enum) {
    slice: []const u8,
    stream: *std.Io.Reader,
};

/// Namespace handling selected at runtime by the normal reader.
pub const NormalNamespacePolicy = enum {
    process,
    raw,
};

/// External-resource handling selected at runtime by the normal reader.
pub const NormalExternalPolicy = enum {
    forbid,
    skip,
    resolve,
};

/// One DTD validity finding borrowed from the Reader or Document that returned it.
pub const NormalDtdFinding = struct {
    code: DiagnosticCode,
    primary: NormalLocation,
    related: ?NormalLocation = null,
    inclusion_trace: []const NormalLocation,
};

/// Action returned by a DTD validity finding callback.
pub const NormalDtdFindingAction = enum {
    continue_validation,
    cancel,
};

/// Synchronous DTD validity finding callback.
pub const NormalDtdFindingSink = struct {
    context: ?*anyopaque,
    report_fn: *const fn (?*anyopaque, NormalDtdFinding) NormalDtdFindingAction,

    /// Reports one borrowed finding.
    pub fn report(self: NormalDtdFindingSink, finding: NormalDtdFinding) NormalDtdFindingAction {
        return self.report_fn(self.context, finding);
    }
};

/// Runtime options used when DTD validation is enabled.
pub const NormalDtdValidationOptions = struct {
    finding_sink: ?NormalDtdFindingSink = null,
    external_subset: ?*const external_subset_module.ExternalSubset = null,
};

/// DTD behavior selected at runtime by the normal reader.
pub const NormalDtdPolicy = union(enum) {
    reject,
    process,
    validate: NormalDtdValidationOptions,
};

/// Runtime XML 1.1 normalization behavior for the normal reader.
pub const NormalNormalizationPolicy = enum {
    report,
    require,
    unchecked,
};

/// Original physical byte range in one XML source.
pub const NormalSourceSpan = struct {
    source_id: u32,
    start: u64,
    end: u64,
};

/// Physical source location with optional line information.
pub const NormalLocation = struct {
    source_id: u32,
    byte_offset: u64,
    line: ?u64,
    byte_column: ?u64,
};

/// Fatal reader diagnostic whose inclusion trace borrows reader storage.
pub const NormalDiagnostic = struct {
    code: DiagnosticCode,
    primary: NormalLocation,
    related: ?NormalLocation,
    inclusion_trace: []const NormalLocation,
};

/// Synchronous fatal diagnostic callback.
pub const NormalDiagnosticSink = struct {
    context: ?*anyopaque,
    report_fn: *const fn (?*anyopaque, NormalDiagnostic) void,

    /// Reports one borrowed fatal diagnostic.
    pub fn report(self: NormalDiagnosticSink, diagnostic: NormalDiagnostic) void {
        self.report_fn(self.context, diagnostic);
    }
};

/// Runtime options retain caller-owned pointers, slices, and callback contexts.
/// Those borrows must remain valid until a successful reset or deinitialization.
pub const NormalReaderOptions = struct {
    limits: NormalLimits = NormalLimits.general,
    namespaces: NormalNamespacePolicy = .process,
    dtd: NormalDtdPolicy = .process,
    external: NormalExternalPolicy = .forbid,
    resolver: ?resolver_module.Resolver = null,
    document_base_id: ?[]const u8 = null,
    /// Decodes the document entity from byte zero instead of using built-in detection.
    transcoder: ?encoding_module.Transcoder = null,
    track_lines: bool = true,
    normalization: NormalNormalizationPolicy = .report,
    diagnostic_sink: ?NormalDiagnosticSink = null,
};

/// Errors reported while constructing the normal reader.
pub const NormalInitError = error{InvalidOptions};

/// Errors reported while producing a normal reader event.
pub const NormalReadError = error{
    InvalidXml,
    UnsupportedVersion,
    InvalidEncoding,
    UnsupportedEncoding,
    DtdForbidden,
    ExternalResourceForbidden,
    ExternalResourceUnavailable,
    ExternalResourceFailed,
    NotNormalized,
    LimitExceeded,
    ReadFailed,
    Cancelled,
    OutOfMemory,
    InvalidState,
};

/// Errors reported while replacing a normal reader source and options.
pub const NormalResetError = error{
    InvalidOptions,
    InvalidState,
};

/// Resolved identity of a namespace-aware name.
pub const NormalExpandedName = struct {
    prefix: ?[]const u8,
    local: []const u8,
    namespace_uri: ?[]const u8,
};

/// Raw name spelling with optional namespace identity.
pub const NormalName = struct {
    raw: []const u8,
    expanded: ?NormalExpandedName,

    /// Returns whether the expanded identity matches.
    pub fn eql(self: NormalName, namespace_uri: ?[]const u8, local: []const u8) bool {
        const expanded = self.expanded orelse return false;
        return optionalBytesOrder(expanded.namespace_uri, namespace_uri) == .eq and
            std.mem.eql(u8, expanded.local, local);
    }

    /// Returns whether the raw source spelling matches.
    pub fn eqlRaw(self: NormalName, raw: []const u8) bool {
        return std.mem.eql(u8, self.raw, raw);
    }
};

/// Attribute borrowed from a start-element event or owned Document.
pub const NormalAttribute = struct {
    name: NormalName,
    value: []const u8,
    span: ?NormalSourceSpan,
    specified: bool,
    declared_type: ?dtd_module.AttributeType,
};

/// Namespace declaration borrowed from one start-element event.
pub const NormalNamespaceDeclaration = struct {
    prefix: ?[]const u8,
    namespace_uri: []const u8,
    span: ?NormalSourceSpan,
    specified: bool,
};

/// XML declaration reported by the normal reader.
pub const NormalXmlDeclaration = struct {
    version: XmlVersion,
    encoding: ?[]const u8,
    standalone: ?bool,
};

/// Document-start information returned by a Reader event or owned Document.
pub const NormalDocumentStart = struct {
    effective_version: XmlVersion,
    source_encoding: SourceEncoding,
    declaration: ?NormalXmlDeclaration,
};

/// Document type header returned by a Reader event or owned Document.
pub const NormalDocumentType = struct {
    root_name: []const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
};

/// Start-element payload.
pub const NormalStartElement = struct {
    name: NormalName,
    attributes: []const NormalAttribute,
    namespace_declarations: []const NormalNamespaceDeclaration,
    empty_syntax: bool,

    /// Returns the first attribute with the requested expanded identity.
    pub fn attribute(
        self: NormalStartElement,
        namespace_uri: ?[]const u8,
        local: []const u8,
    ) ?NormalAttribute {
        for (self.attributes) |value| {
            if (value.name.eql(namespace_uri, local)) return value;
        }
        return null;
    }

    /// Returns the first attribute with the requested raw spelling.
    pub fn attributeRaw(self: NormalStartElement, raw: []const u8) ?NormalAttribute {
        for (self.attributes) |value| {
            if (value.name.eqlRaw(raw)) return value;
        }
        return null;
    }
};

/// End-element payload.
pub const NormalEndElement = struct {
    name: NormalName,
};

/// One fragment of a run of adjacent XML text.
/// `final_fragment` ends the run and may be true on an empty fragment.
pub const NormalText = struct {
    bytes: []const u8,
    origin: TextOrigin,
    final_fragment: bool,
};

/// Comment fragment payload.
pub const NormalComment = struct {
    bytes: []const u8,
    final_fragment: bool,
};

/// Processing-instruction fragment payload.
pub const NormalProcessingInstruction = struct {
    target: []const u8,
    data: []const u8,
    final_fragment: bool,
};

/// Kind of external source intentionally skipped.
pub const NormalSkippedExternalSourceKind = enum {
    external_subset,
    parameter_entity,
    general_entity,
};

/// External source omitted by the selected policy.
pub const NormalSkippedExternalSource = struct {
    kind: NormalSkippedExternalSourceKind,
    name: ?[]const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
};

/// Completeness of parsed document content.
pub const NormalDocumentContent = enum {
    complete,
    external_content_skipped,
};

/// Final DTD validity result.
pub const NormalDtdValidity = enum {
    not_requested,
    valid,
    invalid,
    incomplete,
};

/// Final XML 1.1 normalization result.
pub const NormalDocumentNormalization = enum {
    not_applicable,
    unchecked,
    normalized,
    not_normalized,
    indeterminate,
    incomplete,
};

/// Document-end results.
pub const NormalDocumentEnd = struct {
    content: NormalDocumentContent,
    dtd_validity: NormalDtdValidity,
    normalization: NormalDocumentNormalization,
};

/// Stable event payload for the normal reader.
pub const NormalEventData = union(enum) {
    document_start: NormalDocumentStart,
    document_type: NormalDocumentType,
    start_element: NormalStartElement,
    end_element: NormalEndElement,
    text: NormalText,
    comment: NormalComment,
    processing_instruction: NormalProcessingInstruction,
    skipped_external_source: NormalSkippedExternalSource,
    document_end: NormalDocumentEnd,
};

/// Stable event whose slices remain valid until the next read begins.
pub const NormalEvent = struct {
    span: NormalSourceSpan,
    data: NormalEventData,
};

/// First XML 1.1 normalization finding.
pub const NormalNormalizationFinding = struct {
    kind: NormalizationIssueKind,
    location: NormalLocation,
};

fn PositionState(comptime config: Config) type {
    return if (config.diagnostic_location == .line_column)
        struct {
            line: u64 = 1,
            line_start_offset: u64 = 0,
            pending_carriage_return: bool = false,
        }
    else
        struct {};
}

const VerticalState = enum {
    detect_bom,
    document_start_probe,
    initial_markup,
    emit_document_start,
    release_document_start,
    before_root,
    before_root_markup,
    content,
    content_after_carriage_return,
    content_markup,
    after_root,
    after_root_markup,
    start_name,
    start_after_space,
    attribute_name,
    attribute_after_name,
    attribute_before_value,
    attribute_value,
    attribute_after_carriage_return,
    start_after_attribute,
    empty_slash,
    emit_start_element,
    emit_empty_start_element,
    release_start_attributes,
    release_empty_attributes,
    emit_end_element,
    end_expect_name,
    end_name,
    end_after_space,
    release_closed_element,
    reference_start,
    reference_numeric_prefix,
    reference_numeric,
    reference_entity,
    emit_text,
    release_text,
    markup_declaration_start,
    comment_open,
    comment,
    comment_after_carriage_return,
    emit_comment,
    release_comment,
    cdata_open,
    cdata,
    cdata_after_carriage_return,
    doctype_open,
    doctype,
    emit_document_type,
    finish_doctype,
    emit_dtd_report,
    emit_entity_start,
    emit_entity_end,
    emit_skipped_entity,
    processing_instruction_target,
    processing_instruction_after_target,
    processing_instruction_before_data,
    processing_instruction,
    processing_instruction_after_carriage_return,
    emit_processing_instruction,
    release_processing_instruction,
    declaration,
    declaration_question,
    finish_validation,
    emit_document_end,
    complete,
};

const MarkupContext = enum {
    prolog,
    content,
    epilog,
};

const ReferenceContext = enum {
    content,
    attribute,
};

const ReferenceKind = enum {
    decimal,
    hexadecimal,
};

const ScalarSource = enum {
    ordinary,
    start_tag,
    reference,
};

const LineFollower = enum {
    none,
    nel,
    need_input,
};

const DecodedScalar = struct {
    codepoint: u32,
    len: u3,
};

fn EntitySourceFrame(comptime config: Config) type {
    return struct {
        input: []const u8,
        cursor: usize,
        final_input: bool,
        source_byte_offset: u64,
        source_id: u32,
        position: PositionState(config),
        entity_index: usize,
        open_depth: usize,
        resume_state: VerticalState,
        parent_is_replacement: bool,
        external: if (config.external_sources) bool else void =
            if (config.external_sources) false else {},
        source_encoding: if (config.external_sources) SourceEncoding else void =
            if (config.external_sources) .utf8 else {},
        source_state: if (config.external_sources) SourceState(config) else void =
            if (config.external_sources) .{} else {},
        active_external: if (config.external_sources) ?resolver_module.Source else void =
            if (config.external_sources) null else {},
        active_external_inclusion: if (config.external_sources) ?Location(config) else void =
            if (config.external_sources) null else {},
    };
}

const AttributeEntityFrame = struct {
    bytes: []const u8,
    cursor: usize = 0,
    entity_index: ?usize = null,
};

const ExternalBuffer = struct {
    bytes: []u8,
    source_advances: []u32,
    source_start_offset: u64,
    source_start_line: u64,
    source_start_column: u64,
    source_id: u32,
    base_id: ?[]u8,
    inclusion_source_id: u32,
    inclusion_offset: u64,
    inclusion_line: u64,
    inclusion_column: u64,
};

fn DtdState(comptime config: Config) type {
    return if (config.profile.dtdMode() == .rejected)
        struct {}
    else
        struct {
            declarations: dtd_module.State = .{},
            entity_sources: std.ArrayList(EntitySourceFrame(config)) = .empty,
            attribute_sources: std.ArrayList(AttributeEntityFrame) = .empty,
            reference_name: std.ArrayList(u8) = .empty,
            external_buffers: if (config.external_sources) std.ArrayList(ExternalBuffer) else void =
                if (config.external_sources) .empty else {},
            external_resource_count: if (config.external_sources) usize else void =
                if (config.external_sources) 0 else {},
            external_resource_bytes: if (config.external_sources) usize else void =
                if (config.external_sources) 0 else {},
            external_source_ids: if (config.external_sources) std.ArrayList(u32) else void =
                if (config.external_sources) .empty else {},
            source_id: u32 = 0,
            external_failure_code: if (config.external_sources) ?DiagnosticCode else void =
                if (config.external_sources) null else {},
            external_failure_location: if (config.external_sources) ?Location(config) else void =
                if (config.external_sources) null else {},
            active_external: if (config.external_sources) ?resolver_module.Source else void =
                if (config.external_sources) null else {},
            active_external_inclusion: if (config.external_sources) ?Location(config) else void =
                if (config.external_sources) null else {},
            document_type_emitted: bool = false,
            report_cursor: usize = 0,
            pending_entity_index: usize = 0,
            current_is_replacement: bool = false,
            pending_skipped_entity_index: ?usize = null,
            doctype_data_start: Location(config) = .{},
            seen_doctype: bool = false,
            bracket_depth: usize = 0,
            lexical_state: enum { normal, single_quote, double_quote, comment, pi } = .normal,
        };
}

const Utf8Probe = union(enum) {
    scalar: DecodedScalar,
    incomplete,
    invalid: usize,
};

const NamespaceBinding = struct {
    prefix_offset: usize,
    prefix_len: usize,
    uri_offset: usize,
    uri_len: usize,
    previous_binding: ?usize,
    active_index: usize,
};

const NamespaceReference = union(enum) {
    none,
    predefined_xml,
    binding: usize,
};

const QNameParts = struct {
    prefix: ?[]const u8,
    local: []const u8,
};

const xml_namespace_uri = "http://www.w3.org/XML/1998/namespace";
const xmlns_namespace_uri = "http://www.w3.org/2000/xmlns/";

fn NamespaceState(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            bindings: std.ArrayList(NamespaceBinding) = .empty,
            active_prefixes: std.ArrayList(usize) = .empty,
            bytes: std.ArrayList(u8) = .empty,
            event_declarations: std.ArrayList(NamespaceDeclaration) = .empty,
            expanded_indices: std.ArrayList(usize) = .empty,
            event_attribute_locations: std.ArrayList(Location(config)) = .empty,
            comparison_work: usize = 0,
            reference_colon: ?Location(config) = null,
        }
    else
        struct {};
}

fn OpenElementFrame(comptime config: Config) type {
    return if (config.profile.hasNamespaces())
        struct {
            name_offset: usize,
            name_len: usize,
            start: Location(config),
            namespace_binding_mark: usize,
            namespace_byte_mark: usize,
            namespace_reference: NamespaceReference,
            normalization_content_started: if (config.profile.isXml11()) bool else void =
                if (config.profile.isXml11()) false else {},
            validation: if (config.profile.dtdMode() == .validating)
                validation_module.Frame
            else
                void = if (config.profile.dtdMode() == .validating) .{} else {},
        }
    else
        struct {
            name_offset: usize,
            name_len: usize,
            start: Location(config),
            normalization_content_started: if (config.profile.isXml11()) bool else void =
                if (config.profile.isXml11()) false else {},
            validation: if (config.profile.dtdMode() == .validating)
                validation_module.Frame
            else
                void = if (config.profile.dtdMode() == .validating) .{} else {},
        };
}

fn AttributeRecord(comptime config: Config) type {
    return if (config.profile.hasNamespaces() and config.profile.dtdMode() != .rejected)
        struct {
            name_offset: usize,
            name_len: usize,
            value_len: usize,
            start: Location(config),
            specified: bool = true,
            declared_type: ?dtd_module.AttributeType = null,
            declaration_index: ?usize = null,
            normalization_changed: bool = false,
            namespace_shape: usize = 0,
        }
    else if (config.profile.hasNamespaces())
        struct {
            name_offset: usize,
            name_len: usize,
            value_len: usize,
            start: Location(config),
            namespace_shape: usize = 0,
        }
    else if (config.profile.dtdMode() != .rejected)
        struct {
            name_offset: usize,
            name_len: usize,
            value_len: usize,
            start: Location(config),
            specified: bool = true,
            declared_type: ?dtd_module.AttributeType = null,
            declaration_index: ?usize = null,
            normalization_changed: bool = false,
        }
    else
        struct {
            name_offset: usize,
            name_len: usize,
            value_len: usize,
            start: Location(config),
        };
}

const Failure = enum {
    invalid_xml,
    invalid_dtd,
    not_valid,
    unsupported_feature,
    limit_exceeded,
    out_of_memory,
    resolver_failed,
    read_failed,
    cancelled,
    not_normalized,
};

const decoded_input_capacity = 16 * 1024;
const transcoder_input_capacity = std.math.maxInt(u8);

const EncodingFailure = struct {
    code: DiagnosticCode,
    offset: u64,
    failure: Failure = .invalid_xml,
};

fn isUnsupportedFourByteSignature(bytes: [4]u8) bool {
    return std.mem.eql(u8, &bytes, "\x00\x00\xfe\xff") or
        std.mem.eql(u8, &bytes, "\xff\xfe\x00\x00") or
        std.mem.eql(u8, &bytes, "\x00\x00\xff\xfe") or
        std.mem.eql(u8, &bytes, "\xfe\xff\x00\x00") or
        std.mem.eql(u8, &bytes, "\x00\x00\x00\x3c") or
        std.mem.eql(u8, &bytes, "\x3c\x00\x00\x00") or
        std.mem.eql(u8, &bytes, "\x00\x00\x3c\x00") or
        std.mem.eql(u8, &bytes, "\x00\x3c\x00\x00");
}

fn hasTranscoderState(comptime config: Config) bool {
    if (config.external_sources) return true;
    return switch (config.profile) {
        .xml11_no_dtd, .xml11_ns_no_dtd => true,
        else => false,
    };
}

fn ExternalDecoderState(comptime config: Config) type {
    return if (!hasTranscoderState(config))
        struct {}
    else
        struct {
            raw: std.ArrayList(u8) = .empty,
            transcoder: ?encoding_module.Transcoder = null,
            needs_input: bool = false,
            finished: bool = false,
            eof: bool = false,
            at_start: bool = true,
        };
}

const SourceNormalizationIssue = struct {
    kind: NormalizationIssueKind,
    byte_offset: u64,
    line: u64,
    byte_column: u64,
};

const SourceNormalization = struct {
    checker: unicode_normalization.Checker = .{},
    utf8_bytes: [4]u8 = @splat(0),
    utf8_len: u3 = 0,
    utf8_expected_len: u3 = 0,
    utf8_start_offset: u64 = 0,
    utf8_source_width: u64 = 0,
    scanned_raw_offset: u64 = 0,
    line: u64 = 1,
    byte_column: u64 = 1,
    previous_was_carriage_return: bool = false,
    issue: ?SourceNormalizationIssue = null,
    definite_issue: ?SourceNormalizationIssue = null,
    issue_reported: bool = false,
    definite_issue_reported: bool = false,

    fn reset(self: *SourceNormalization) void {
        self.* = .{};
    }
};

fn advanceSourceNormalization(
    normalization: *SourceNormalization,
    codepoint: u21,
    source_width: u64,
) void {
    if (normalization.previous_was_carriage_return and
        (codepoint == '\n' or codepoint == 0x85))
    {
        normalization.previous_was_carriage_return = false;
        return;
    }
    normalization.previous_was_carriage_return = codepoint == '\r';
    if (codepoint == '\r' or codepoint == '\n' or codepoint == 0x85 or codepoint == 0x2028) {
        normalization.line += 1;
        normalization.byte_column = 1;
    } else {
        normalization.byte_column += source_width;
    }
}

fn SourceState(comptime config: Config) type {
    return if (config.profile.isUtf8Only())
        struct {}
    else
        struct {
            raw_input: []const u8 = &.{},
            raw_cursor: usize = 0,
            raw_final: bool = false,
            raw_offset: u64 = 0,
            encoding: ?SourceEncoding = null,
            signature_bytes: [4]u8 = @splat(0),
            signature_len: usize = 0,
            decoded: std.ArrayList(u8) = .empty,
            source_advances: std.ArrayList(u8) = .empty,
            input_is_direct_utf8: bool = false,
            line_pending: if (config.profile.isXml11()) [3]u8 else void =
                if (config.profile.isXml11()) @splat(0) else {},
            line_pending_advances: if (config.profile.isXml11()) [3]u8 else void =
                if (config.profile.isXml11()) @splat(0) else {},
            line_pending_len: if (config.profile.isXml11()) u2 else void =
                if (config.profile.isXml11()) 0 else {},
            pending_byte: ?u8 = null,
            pending_byte_offset: u64 = 0,
            high_surrogate: ?u16 = null,
            high_surrogate_offset: u64 = 0,
            failure: ?EncodingFailure = null,
            external: ExternalDecoderState(config) = .{},
            normalization: if (config.profile.isXml11()) SourceNormalization else void =
                if (config.profile.isXml11()) .{} else {},
        };
}

const InternalReadError = ReadError || error{RefillDecodedInput};

/// Incremental reader specialized to `config`.
pub fn Reader(comptime config: Config) type {
    config.validate();

    return struct {
        const Self = @This();
        const no_end_mismatch = std.math.maxInt(usize);
        const linear_duplicate_threshold = 64;

        allocator: std.mem.Allocator,
        options: Options(config),
        lifecycle: Lifecycle = .ready,
        input: []const u8 = &.{},
        cursor: usize = 0,
        final_input: bool = false,
        final_was_seen: bool = false,
        source_byte_offset: u64 = 0,
        source_encoding: SourceEncoding = .utf8,
        source_state: SourceState(config) = .{},
        position: PositionState(config) = .{},
        first_diagnostic: ?Diagnostic(config) = null,
        diagnostic_inclusions: if (config.external_sources)
            std.ArrayList(Location(config))
        else
            void = if (config.external_sources) .empty else {},
        vertical_state: VerticalState = .detect_bom,
        failure: ?Failure = null,
        open_elements: std.ArrayList(OpenElementFrame(config)) = .empty,
        open_names: std.ArrayList(u8) = .empty,
        attribute_records: std.ArrayList(AttributeRecord(config)) = .empty,
        attribute_bytes: std.ArrayList(u8) = .empty,
        declaration_source_advances: std.ArrayList(u8) = .empty,
        event_attributes: std.ArrayList(Attribute(config)) = .empty,
        namespace_state: NamespaceState(config) = .{},
        dtd_state: DtdState(config) = .{},
        validation_state: if (config.profile.dtdMode() == .validating)
            validation_module.State
        else
            void = if (config.profile.dtdMode() == .validating) .{} else {},
        validity_errors: if (config.profile.dtdMode() == .validating) usize else void =
            if (config.profile.dtdMode() == .validating) 0 else {},
        validation_incomplete: if (config.profile.dtdMode() == .validating) bool else void =
            if (config.profile.dtdMode() == .validating) false else {},
        validation_declarations_incomplete: if (config.profile.dtdMode() == .validating)
            bool
        else
            void = if (config.profile.dtdMode() == .validating) false else {},
        validation_parameter_entity_skipped: if (config.profile.dtdMode() == .validating)
            bool
        else
            void = if (config.profile.dtdMode() == .validating) false else {},
        final_idref_cursor: if (config.profile.dtdMode() == .validating) usize else void =
            if (config.profile.dtdMode() == .validating) 0 else {},
        token_start: Location(config) = .{},
        token_name_len: usize = 0,
        end_mismatch_index: usize = no_end_mismatch,
        end_mismatch_location: Location(config) = .{},
        attribute_quote: u8 = 0,
        utf8_bytes: [4]u8 = @splat(0),
        utf8_len: u3 = 0,
        utf8_expected_len: u3 = 0,
        utf8_start: Location(config) = .{},
        utf8_source_advances: [4]u8 = @splat(0),
        text_inline: [4]u8 = @splat(0),
        text_fragment: []const u8 = &.{},
        text_from_reference: bool = false,
        text_start: Location(config) = .{},
        text_close_brackets: u2 = 0,
        reference_context: ReferenceContext = .content,
        reference_kind: ReferenceKind = .decimal,
        reference_start: Location(config) = .{},
        reference_value: u32 = 0,
        reference_has_digits: bool = false,
        reference_token_bytes: usize = 0,
        reference_name: [5]u8 = @splat(0),
        reference_name_len: usize = 0,
        document_start_resume: VerticalState = .before_root,
        document_start_span: Location(config) = .{},
        declared_version_offset: usize = 0,
        declared_version_len: usize = 0,
        effective_version: if (config.profile.isXml11()) XmlVersion else void =
            if (config.profile.isXml11()) .xml10 else {},
        normalization_status: if (config.profile.isXml11()) NormalizationStatus else void =
            if (config.profile.isXml11()) .unchecked else {},
        normalization_issue: if (config.profile.isXml11()) ?NormalizationIssue(config) else void =
            if (config.profile.isXml11()) null else {},
        construct_checker: if (config.profile.isXml11()) unicode_normalization.Checker else void =
            if (config.profile.isXml11()) .{} else {},
        construct_started: if (config.profile.isXml11()) bool else void =
            if (config.profile.isXml11()) false else {},
        cdata_started: if (config.profile.isXml11()) bool else void =
            if (config.profile.isXml11()) false else {},
        declared_encoding_offset: usize = 0,
        declared_encoding_len: usize = 0,
        standalone: bool = false,
        standalone_declared: bool = false,
        markup_context: MarkupContext = .prolog,
        delimiter_index: usize = 0,
        delimiter_bytes: [2]u8 = @splat(0),
        delimiter_len: u2 = 0,
        delimiter_start: Location(config) = .{},
        fragment_complete: bool = false,
        text_origin: TextOrigin = .character_data,
        text_resume: VerticalState = .content,
        processing_instruction_initial: bool = false,
        processing_instruction_target_len: usize = 0,
        declaration_data_start: Location(config) = .{},
        declaration_question_advance: u8 = 0,

        /// Initializes a reader without allocating.
        pub fn init(allocator: std.mem.Allocator, options: Options(config)) InitError!Self {
            if (!options.limits.validate() or !options.namespace_limits.validate()) {
                return error.InvalidOptions;
            }
            if (comptime config.profile.dtdMode() != .rejected) {
                if (!options.dtd_limits.validate()) {
                    return error.InvalidOptions;
                }
            }
            if (comptime config.profile.dtdMode() == .validating) {
                if (!options.validation.limits.validate()) return error.InvalidOptions;
            }
            if (comptime config.external_sources) {
                if (!options.resolver.validate()) return error.InvalidOptions;
            }
            return .{
                .allocator = allocator,
                .options = options,
            };
        }

        /// Releases all reader-owned memory and invalidates the reader.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.lifecycle != .deinitialized);
            self.releaseStorage();
            self.input = &.{};
            self.cursor = 0;
            self.first_diagnostic = null;
            self.lifecycle = .deinitialized;
        }

        /// Clears document state using the selected capacity policy.
        pub fn reset(self: *Self, mode: ResetMode) ResetError!void {
            if (self.lifecycle == .deinitialized) return error.InvalidState;
            switch (mode) {
                .retain_capacity => {
                    if (self.retainedCapacity() > self.options.limits.max_retained_bytes) {
                        self.releaseStorage();
                    } else {
                        self.open_elements.clearRetainingCapacity();
                        self.open_names.clearRetainingCapacity();
                        self.clearAttributesRetainingCapacity();
                        self.clearNamespacesRetainingCapacity();
                        self.clearDtdRetainingCapacity();
                        if (comptime config.profile.dtdMode() == .validating) {
                            self.validation_state.clearRetainingCapacity();
                        }
                    }
                },
                .release_memory => self.releaseStorage(),
            }
            if (comptime config.external_sources) {
                self.diagnostic_inclusions.clearRetainingCapacity();
            }
            self.lifecycle = .ready;
            self.input = &.{};
            self.cursor = 0;
            self.final_input = false;
            self.final_was_seen = false;
            self.source_byte_offset = 0;
            self.source_encoding = .utf8;
            self.resetSourceStateRetainingCapacity();
            self.position = .{};
            self.first_diagnostic = null;
            self.vertical_state = .detect_bom;
            self.failure = null;
            self.token_start = .{};
            self.token_name_len = 0;
            self.end_mismatch_index = no_end_mismatch;
            self.end_mismatch_location = .{};
            self.attribute_quote = 0;
            self.utf8_bytes = @splat(0);
            self.utf8_len = 0;
            self.utf8_expected_len = 0;
            self.utf8_start = .{};
            self.utf8_source_advances = @splat(0);
            self.text_inline = @splat(0);
            self.text_fragment = &.{};
            self.text_from_reference = false;
            self.text_start = .{};
            self.text_close_brackets = 0;
            self.reference_context = .content;
            self.reference_kind = .decimal;
            self.reference_start = .{};
            self.reference_value = 0;
            self.reference_has_digits = false;
            self.reference_token_bytes = 0;
            self.reference_name = @splat(0);
            self.reference_name_len = 0;
            if (comptime config.profile.dtdMode() != .rejected) {
                self.dtd_state.reference_name.clearRetainingCapacity();
                self.dtd_state.current_is_replacement = false;
            }
            self.document_start_resume = .before_root;
            self.document_start_span = .{};
            self.declared_version_offset = 0;
            self.declared_version_len = 0;
            if (comptime config.profile.isXml11()) self.effective_version = .xml10;
            if (comptime config.profile.isXml11()) {
                self.normalization_status = .unchecked;
                self.normalization_issue = null;
                self.construct_checker.reset();
                self.construct_started = false;
                self.cdata_started = false;
            }
            self.declared_encoding_offset = 0;
            self.declared_encoding_len = 0;
            self.standalone = false;
            self.standalone_declared = false;
            self.markup_context = .prolog;
            self.delimiter_index = 0;
            self.delimiter_bytes = @splat(0);
            self.delimiter_len = 0;
            self.delimiter_start = .{};
            self.fragment_complete = false;
            self.text_origin = .character_data;
            self.text_resume = .content;
            self.processing_instruction_initial = false;
            self.processing_instruction_target_len = 0;
            self.declaration_data_start = .{};
            self.declaration_question_advance = 0;
            if (comptime config.profile.dtdMode() == .validating) {
                self.validity_errors = 0;
                self.validation_incomplete = false;
                self.validation_declarations_incomplete = false;
                self.validation_parameter_entity_skipped = false;
                self.final_idref_cursor = 0;
            }
            if (comptime config.profile.dtdMode() != .rejected) {
                self.dtd_state.report_cursor = 0;
                self.dtd_state.document_type_emitted = false;
                self.dtd_state.seen_doctype = false;
                self.dtd_state.bracket_depth = 0;
                self.dtd_state.lexical_state = .normal;
                self.dtd_state.doctype_data_start = .{};
            }
        }

        /// Installs one caller-owned input chunk.
        pub fn feed(self: *Self, input: []const u8, final: bool) FeedError!void {
            if (self.lifecycle != .ready and self.lifecycle != .needs_input) {
                return error.InvalidState;
            }
            if (self.final_was_seen or (input.len == 0 and !final)) {
                return error.InvalidState;
            }

            if (comptime config.profile.isUtf8Only()) {
                self.input = input;
                self.cursor = 0;
                self.final_input = final;
            } else {
                self.source_state.raw_input = input;
                self.source_state.raw_cursor = 0;
                self.source_state.raw_final = final;
                self.input = &.{};
                self.cursor = 0;
                self.final_input = false;
            }
            self.final_was_seen = final;
            self.lifecycle = .producing;
        }

        fn feedTranscodedRoot(self: *Self, input: []const u8, final: bool) ReadError!void {
            if (comptime config.profile.isUtf8Only() or !hasTranscoderState(config)) unreachable;
            if (self.lifecycle != .ready and self.lifecycle != .needs_input) {
                return error.InvalidState;
            }
            if (self.final_was_seen or (input.len == 0 and !final)) {
                return error.InvalidState;
            }

            const source = &self.source_state;
            const pending = source.raw_input[source.raw_cursor..];
            if (pending.len > transcoder_input_capacity or
                input.len > transcoder_input_capacity - pending.len)
            {
                return self.failAt(
                    .malformed_encoding,
                    .invalid_xml,
                    self.locationAtCurrentLine(source.raw_offset),
                );
            }
            if (pending.len != 0) {
                std.mem.copyForwards(
                    u8,
                    source.external.raw.items[0..pending.len],
                    pending,
                );
            }
            source.external.raw.items.len = pending.len;
            source.external.raw.ensureUnusedCapacity(self.allocator, input.len) catch
                return self.failOutOfMemory();
            source.external.raw.appendSliceAssumeCapacity(input);
            source.raw_input = source.external.raw.items;
            source.raw_cursor = 0;
            source.raw_final = final;
            source.external.needs_input = false;
            self.input = &.{};
            self.cursor = 0;
            self.final_input = false;
            self.final_was_seen = final;
            self.lifecycle = .producing;
        }

        /// Produces the next semantic event.
        pub fn next(self: *Self) ReadError!Step(config) {
            while (true) {
                return self.nextParser() catch |err| switch (err) {
                    error.RefillDecodedInput => continue,
                    else => |read_error| return read_error,
                };
            }
        }

        fn nextParser(self: *Self) InternalReadError!Step(config) {
            switch (self.lifecycle) {
                .ready, .needs_input, .deinitialized => return error.InvalidState,
                .failed => return self.failureError(),
                .done => return .done,
                .producing => {},
            }
            if (comptime !config.profile.isUtf8Only()) {
                const internal_entity_active = if (comptime config.profile.dtdMode() == .rejected)
                    false
                else
                    self.dtd_state.entity_sources.items.len != 0;
                if (self.cursor == self.input.len and !self.final_input and !internal_entity_active) {
                    return self.needInput();
                }
            }

            while (true) {
                if (comptime config.profile.isXml11()) {
                    if (self.normalization_status != .unchecked) {
                        try self.mergeSourceNormalization();
                    }
                }
                switch (self.vertical_state) {
                    .detect_bom => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            self.clearUtf8Scalar();
                            if (scalar.codepoint == 0xfeff) {
                                self.vertical_state = .document_start_probe;
                                continue;
                            }
                            return self.failAt(.unexpected_document_text, .invalid_xml, start);
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                self.vertical_state = .document_start_probe;
                                continue;
                            }
                            return self.needInput();
                        }
                        if (self.utf8_len == 0 and self.input[self.cursor] < 0x80) {
                            self.vertical_state = .document_start_probe;
                            continue;
                        }
                        const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                            return self.needInput();
                        const start = self.utf8_start;
                        if (!self.isLiteralChar(scalar.codepoint)) {
                            return self.failAt(.forbidden_character, .invalid_xml, start);
                        }
                        self.clearUtf8Scalar();
                        if (scalar.codepoint == 0xfeff) {
                            self.vertical_state = .document_start_probe;
                            continue;
                        }
                        return self.failAt(.unexpected_document_text, .invalid_xml, start);
                    },
                    .document_start_probe => {
                        if (self.cursor == self.input.len) {
                            if (!self.final_input) return self.needInput();
                            self.document_start_span = self.currentLocation();
                            self.document_start_resume = .before_root;
                            self.vertical_state = .emit_document_start;
                            continue;
                        }
                        if (self.input[self.cursor] != '<') {
                            self.document_start_span = self.currentLocation();
                            self.document_start_resume = .before_root;
                            self.vertical_state = .emit_document_start;
                            continue;
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .initial_markup;
                    },
                    .initial_markup => {
                        if (self.cursor == self.input.len) {
                            if (!self.final_input) return self.needInput();
                            self.document_start_span = self.token_start;
                            self.document_start_resume = .before_root_markup;
                            self.vertical_state = .emit_document_start;
                            continue;
                        }
                        if (self.input[self.cursor] == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.prolog, true);
                            continue;
                        }
                        self.document_start_span = self.token_start;
                        self.document_start_resume = .before_root_markup;
                        self.vertical_state = .emit_document_start;
                    },
                    .emit_document_start => {
                        self.vertical_state = self.document_start_resume;
                        const end = self.currentLocation();
                        return self.eventStep(
                            .{ .document_start = self.documentStart() },
                            self.document_start_span,
                            end,
                        );
                    },
                    .release_document_start => {
                        self.clearAttributesRetainingCapacity();
                        self.vertical_state = .before_root;
                    },
                    .before_root => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            return self.failAt(
                                .unexpected_document_text,
                                .invalid_xml,
                                start,
                            );
                        }
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.empty_document, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            const byte = self.input[self.cursor];
                            if (byte >= 0x80) {
                                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                    return self.needInput();
                                const start = self.utf8_start;
                                if (!self.isLiteralChar(scalar.codepoint)) {
                                    return self.failAt(
                                        .forbidden_character,
                                        .invalid_xml,
                                        start,
                                    );
                                }
                                return self.failAt(
                                    .unexpected_document_text,
                                    .invalid_xml,
                                    start,
                                );
                            }
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.unexpected_document_text, .invalid_xml);
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .before_root_markup;
                    },
                    .before_root_markup => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '!') {
                            self.consumeByte('!');
                            self.beginMarkupDeclaration(.prolog);
                            continue;
                        }
                        if (byte == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.prolog, false);
                            continue;
                        }
                        if (byte == '/') {
                            return self.fail(.unexpected_end_tag, .invalid_xml);
                        }
                        if (byte >= 0x80 or isAsciiNameStart(byte)) {
                            try self.beginStartElement();
                            continue;
                        }
                        if (!self.isLiteralChar(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        if (!isAsciiNameStart(byte)) {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                    },
                    .content => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (self.isXml11LineEnd(scalar.codepoint)) {
                                self.recordXml11LineEnd(false);
                                self.text_close_brackets = 0;
                                try self.prepareInlineText("\n", start);
                                self.clearUtf8Scalar();
                                continue;
                            }
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            self.text_close_brackets = 0;
                            try self.prepareInlineText(
                                self.utf8_bytes[0..scalar.len],
                                start,
                            );
                            self.clearUtf8Scalar();
                            continue;
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                const frame = self.topFrame();
                                return self.failRelated(
                                    .unclosed_element,
                                    .invalid_xml,
                                    self.currentLocation(),
                                    frame.start,
                                );
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '<') {
                            self.text_close_brackets = 0;
                            self.markContentMarkup();
                            self.token_start = self.currentLocation();
                            self.consumeByte('<');
                            self.vertical_state = .content_markup;
                            continue;
                        }
                        if (byte == '&') {
                            self.text_close_brackets = 0;
                            if (comptime config.profile.isXml11()) {
                                self.construct_started = false;
                            }
                            if (try self.prepareCompleteContentReference()) continue;
                            try self.beginReference(.content);
                            continue;
                        }
                        if (byte == '\r') {
                            self.text_close_brackets = 0;
                            self.text_start = self.currentLocation();
                            self.consumeByte(byte);
                            if (comptime config.profile.dtdMode() != .rejected) {
                                if (self.dtd_state.current_is_replacement) {
                                    try self.prepareInlineText("\r", self.text_start);
                                    continue;
                                }
                            }
                            self.vertical_state = .content_after_carriage_return;
                            continue;
                        }
                        if (try self.prepareContentRun()) continue;
                        const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                            return self.needInput();
                        const start = self.utf8_start;
                        if (self.isXml11LineEnd(scalar.codepoint)) {
                            self.recordXml11LineEnd(false);
                            self.text_close_brackets = 0;
                            try self.prepareInlineText("\n", start);
                            self.clearUtf8Scalar();
                            continue;
                        }
                        if (!self.isLiteralChar(scalar.codepoint)) {
                            return self.failAt(.forbidden_character, .invalid_xml, start);
                        }
                        self.text_close_brackets = 0;
                        try self.prepareInlineText(
                            self.utf8_bytes[0..scalar.len],
                            start,
                        );
                        self.clearUtf8Scalar();
                    },
                    .content_after_carriage_return => {
                        if (self.cursor == self.input.len and !self.final_input) {
                            return self.needInput();
                        }
                        if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                            self.consumeByte('\n');
                        } else switch (try self.consumeNelAfterCarriageReturn(.ordinary)) {
                            .need_input => return self.needInput(),
                            .none, .nel => {},
                        }
                        try self.prepareInlineText(
                            "\n",
                            self.text_start,
                        );
                    },
                    .content_markup => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '/') {
                            self.consumeByte('/');
                            self.vertical_state = .end_expect_name;
                            continue;
                        }
                        if (byte == '!') {
                            self.consumeByte('!');
                            self.beginMarkupDeclaration(.content);
                            continue;
                        }
                        if (byte == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.content, false);
                            continue;
                        }
                        if (byte >= 0x80 or isAsciiNameStart(byte)) {
                            try self.beginStartElement();
                            continue;
                        }
                        if (!self.isLiteralChar(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        if (!isAsciiNameStart(byte)) {
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                    },
                    .after_root => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            return self.failAt(.trailing_content, .invalid_xml, start);
                        }
                        self.consumeWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                self.vertical_state = if (comptime config.profile.dtdMode() == .validating)
                                    .finish_validation
                                else
                                    .emit_document_end;
                                continue;
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '<') {
                            const byte = self.input[self.cursor];
                            if (byte >= 0x80) {
                                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                    return self.needInput();
                                const start = self.utf8_start;
                                if (!self.isLiteralChar(scalar.codepoint)) {
                                    return self.failAt(
                                        .forbidden_character,
                                        .invalid_xml,
                                        start,
                                    );
                                }
                                return self.failAt(.trailing_content, .invalid_xml, start);
                            }
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.trailing_content, .invalid_xml);
                        }
                        self.token_start = self.currentLocation();
                        self.consumeByte('<');
                        self.vertical_state = .after_root_markup;
                    },
                    .after_root_markup => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            if (isXml10NameStart(scalar.codepoint)) {
                                return self.failAt(
                                    .multiple_document_elements,
                                    .invalid_xml,
                                    self.token_start,
                                );
                            }
                            return self.failAt(.trailing_content, .invalid_xml, start);
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte == '/') {
                            return self.fail(.unexpected_end_tag, .invalid_xml);
                        }
                        if (byte == '!') {
                            self.consumeByte('!');
                            self.beginMarkupDeclaration(.epilog);
                            continue;
                        }
                        if (byte == '?') {
                            self.consumeByte('?');
                            try self.beginProcessingInstruction(.epilog, false);
                            continue;
                        }
                        if (byte >= 0x80) {
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            if (isXml10NameStart(scalar.codepoint)) {
                                return self.failAt(
                                    .multiple_document_elements,
                                    .invalid_xml,
                                    self.token_start,
                                );
                            }
                            return self.failAt(.trailing_content, .invalid_xml, start);
                        }
                        if (isAsciiNameStart(byte)) {
                            return self.failAt(
                                .multiple_document_elements,
                                .invalid_xml,
                                self.token_start,
                            );
                        }
                        if (!self.isLiteralChar(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        return self.fail(.trailing_content, .invalid_xml);
                    },
                    .start_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (self.utf8_len == 0 and run_end < self.input.len and
                            isAsciiNameChar(self.input[run_end]))
                        {
                            run_end += 1;
                        }
                        try self.appendStartNameRun(self.input[run_start..run_end]);

                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            try self.ensureStartNameScalarCapacity();
                            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                return self.needInput();
                            const scalar_start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(
                                    .forbidden_character,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            const valid = if (self.token_name_len == 0)
                                isXml10NameStart(scalar.codepoint)
                            else
                                isXml10NameChar(scalar.codepoint);
                            if (!valid) {
                                return self.failAt(
                                    .malformed_start_tag,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            try self.appendDecodedStartName(scalar.len);
                            self.clearUtf8Scalar();
                            continue;
                        }

                        if (self.cursor < self.input.len) {
                            try self.requireStartTagByte();
                            const byte = self.input[self.cursor];
                            if (byte == '/') {
                                self.consumeStartTagByte(byte);
                                self.vertical_state = .empty_slash;
                                continue;
                            }
                            if (byte == '>') {
                                self.consumeStartTagByte(byte);
                                try self.finishStartElement(false);
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.vertical_state = .start_after_space;
                                continue;
                            }
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .start_after_space => {
                        try self.consumeStartTagWhitespaceRun();
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        const byte = self.input[self.cursor];
                        if (byte == '>') {
                            self.consumeStartTagByte(byte);
                            try self.finishStartElement(false);
                            continue;
                        }
                        if (byte == '/') {
                            self.consumeStartTagByte(byte);
                            self.vertical_state = .empty_slash;
                            continue;
                        }
                        if (byte >= 0x80 or isAsciiNameStart(byte)) {
                            try self.beginAttribute();
                            continue;
                        }
                        if (!self.isLiteralChar(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        return self.fail(.malformed_attribute, .invalid_xml);
                    },
                    .attribute_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (self.utf8_len == 0 and run_end < self.input.len and
                            isAsciiNameChar(self.input[run_end]))
                        {
                            run_end += 1;
                        }
                        try self.appendAttributeNameRun(self.input[run_start..run_end]);

                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            try self.ensureAttributeNameScalarCapacity();
                            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                return self.needInput();
                            const scalar_start = self.utf8_start;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(
                                    .forbidden_character,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            const record = self.attribute_records.items[
                                self.attribute_records.items.len - 1
                            ];
                            const valid = if (record.name_len == 0)
                                isXml10NameStart(scalar.codepoint)
                            else
                                isXml10NameChar(scalar.codepoint);
                            if (!valid) {
                                return self.failAt(
                                    .malformed_attribute,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            try self.appendDecodedAttributeName(scalar.len);
                            self.clearUtf8Scalar();
                            continue;
                        }

                        if (self.cursor < self.input.len) {
                            try self.requireStartTagByte();
                            const byte = self.input[self.cursor];
                            if (byte == '=') {
                                self.consumeStartTagByte(byte);
                                self.vertical_state = .attribute_before_value;
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.vertical_state = .attribute_after_name;
                                continue;
                            }
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .attribute_after_name => {
                        try self.consumeStartTagWhitespaceRun();
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_attribute)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        if (self.input[self.cursor] != '=') {
                            if (!self.isLiteralChar(self.input[self.cursor])) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        self.consumeStartTagByte('=');
                        self.vertical_state = .attribute_before_value;
                    },
                    .attribute_before_value => {
                        try self.consumeStartTagWhitespaceRun();
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_attribute)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        const byte = self.input[self.cursor];
                        if (byte != '\'' and byte != '"') {
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        self.attribute_quote = byte;
                        self.consumeStartTagByte(byte);
                        self.vertical_state = .attribute_value;
                    },
                    .attribute_value => {
                        if (self.utf8_len != 0) {
                            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                return self.needInput();
                            const start = self.utf8_start;
                            if (self.isXml11LineEnd(scalar.codepoint)) {
                                self.recordXml11LineEnd(false);
                                try self.appendAttributeOutput(" ");
                                self.clearUtf8Scalar();
                                continue;
                            }
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            try self.appendAttributeOutput(self.utf8_bytes[0..scalar.len]);
                            self.clearUtf8Scalar();
                            continue;
                        }
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (run_end < self.input.len and
                            isOrdinaryAttributeValueByte(self.input[run_end], self.attribute_quote))
                        {
                            run_end += 1;
                        }
                        try self.appendAttributeValueRun(self.input[run_start..run_end]);

                        if (self.cursor < self.input.len) {
                            try self.requireStartTagByte();
                            const byte = self.input[self.cursor];
                            if (byte == self.attribute_quote) {
                                self.consumeStartTagByte(byte);
                                self.finishAttribute();
                                self.vertical_state = .start_after_attribute;
                                continue;
                            }
                            if (byte == '<') {
                                return self.fail(.attribute_less_than, .invalid_xml);
                            }
                            if (byte == '&') {
                                try self.beginReference(.attribute);
                                continue;
                            }
                            if (byte == '\r') {
                                self.consumeStartTagByte(byte);
                                self.vertical_state = .attribute_after_carriage_return;
                                continue;
                            }
                            if (byte == '\n' or byte == '\t') {
                                self.consumeStartTagByte(byte);
                                try self.appendAttributeOutput(" ");
                                continue;
                            }
                            if (byte >= 0x80) {
                                try self.ensureAttributeValueScalarCapacity();
                                const scalar = (try self.readUtf8Scalar(.start_tag)) orelse
                                    return self.needInput();
                                const start = self.utf8_start;
                                if (self.isXml11LineEnd(scalar.codepoint)) {
                                    self.recordXml11LineEnd(false);
                                    try self.appendAttributeOutput(" ");
                                    self.clearUtf8Scalar();
                                    continue;
                                }
                                if (!self.isLiteralChar(scalar.codepoint)) {
                                    return self.failAt(
                                        .forbidden_character,
                                        .invalid_xml,
                                        start,
                                    );
                                }
                                try self.appendAttributeOutput(
                                    self.utf8_bytes[0..scalar.len],
                                );
                                self.clearUtf8Scalar();
                                continue;
                            }
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_attribute, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .attribute_after_carriage_return => {
                        if (self.cursor == self.input.len and !self.final_input) {
                            return self.needInput();
                        }
                        if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                            try self.requireStartTagByte();
                            self.consumeStartTagByte('\n');
                        } else switch (try self.consumeNelAfterCarriageReturn(.start_tag)) {
                            .need_input => return self.needInput(),
                            .none, .nel => {},
                        }
                        try self.appendAttributeOutput(" ");
                        self.vertical_state = .attribute_value;
                    },
                    .start_after_attribute => {
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_attribute)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        const byte = self.input[self.cursor];
                        if (byte == '>') {
                            self.consumeStartTagByte(byte);
                            try self.finishStartElement(false);
                            continue;
                        }
                        if (byte == '/') {
                            self.consumeStartTagByte(byte);
                            self.vertical_state = .empty_slash;
                            continue;
                        }
                        if (isXmlWhitespace(byte)) {
                            self.vertical_state = .start_after_space;
                            continue;
                        }
                        if (!self.isLiteralChar(byte)) {
                            return self.fail(.forbidden_character, .invalid_xml);
                        }
                        return self.fail(.malformed_attribute, .invalid_xml);
                    },
                    .empty_slash => {
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectStartTagNonAsciiMarkup(.malformed_start_tag)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        try self.requireStartTagByte();
                        if (self.input[self.cursor] != '>') {
                            if (!self.isLiteralChar(self.input[self.cursor])) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_start_tag, .invalid_xml);
                        }
                        self.consumeStartTagByte('>');
                        try self.finishStartElement(true);
                    },
                    .emit_start_element => {
                        self.vertical_state = .release_start_attributes;
                        return self.eventStep(
                            .{ .start_element = self.startElement(false) },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .emit_empty_start_element => {
                        self.vertical_state = .release_empty_attributes;
                        return self.eventStep(
                            .{ .start_element = self.startElement(true) },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .release_start_attributes => {
                        self.clearAttributesRetainingCapacity();
                        self.vertical_state = .content;
                    },
                    .release_empty_attributes => {
                        self.clearAttributesRetainingCapacity();
                        self.vertical_state = .emit_end_element;
                    },
                    .emit_end_element => {
                        self.vertical_state = .release_closed_element;
                        return self.eventStep(
                            .{ .end_element = .{ .name = self.topName() } },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .end_expect_name => {
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        const byte = self.input[self.cursor];
                        if (byte < 0x80 and !isAsciiNameStart(byte)) {
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        self.token_name_len = 0;
                        self.end_mismatch_index = no_end_mismatch;
                        self.end_mismatch_location = .{};
                        self.vertical_state = .end_name;
                    },
                    .end_name => {
                        const run_start = self.cursor;
                        var run_end = run_start;
                        while (self.utf8_len == 0 and run_end < self.input.len and
                            isAsciiNameChar(self.input[run_end]))
                        {
                            run_end += 1;
                        }
                        try self.compareAndConsumeEndName(self.input[run_start..run_end]);

                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            const scalar_start = if (self.utf8_len == 0)
                                self.currentLocation()
                            else
                                self.utf8_start;
                            const scalar_len = self.pendingUtf8ScalarLength() catch
                                return self.fail(.malformed_utf8, .invalid_xml);
                            if (scalar_len > self.options.limits.max_partial_token_bytes -
                                self.token_name_len)
                            {
                                return self.failVoid(.partial_token_limit, .limit_exceeded);
                            }
                            if (scalar_len > self.qnameRemaining(self.token_name_len)) {
                                return self.failVoid(.qname_limit, .limit_exceeded);
                            }
                            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse
                                return self.needInput();
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                return self.failAt(
                                    .forbidden_character,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            const valid = if (self.token_name_len == 0)
                                isXml10NameStart(scalar.codepoint)
                            else
                                isXml10NameChar(scalar.codepoint);
                            if (!valid) {
                                return self.failAt(
                                    .malformed_end_tag,
                                    .invalid_xml,
                                    scalar_start,
                                );
                            }
                            try self.compareDecodedEndName(scalar.len);
                            self.clearUtf8Scalar();
                            continue;
                        }

                        if (self.cursor < self.input.len) {
                            const byte = self.input[self.cursor];
                            if (byte == '>') {
                                self.recordShortEndMismatch();
                                self.consumeByte(byte);
                                try self.finishEndElement();
                                continue;
                            }
                            if (isXmlWhitespace(byte)) {
                                self.recordShortEndMismatch();
                                self.vertical_state = .end_after_space;
                                continue;
                            }
                            if (!self.isLiteralChar(byte)) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        if (self.final_input) {
                            return self.fail(.incomplete_input, .invalid_xml);
                        }
                        return self.needInput();
                    },
                    .end_after_space => {
                        self.consumeWhitespaceRun();
                        if (self.utf8_len != 0 or
                            (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
                        {
                            if (try self.rejectNonAsciiMarkup(.malformed_end_tag)) {
                                return self.needInput();
                            }
                        }
                        if (self.cursor == self.input.len) {
                            if (self.final_input) {
                                return self.fail(.incomplete_input, .invalid_xml);
                            }
                            return self.needInput();
                        }
                        if (self.input[self.cursor] != '>') {
                            if (!self.isLiteralChar(self.input[self.cursor])) {
                                return self.fail(.forbidden_character, .invalid_xml);
                            }
                            return self.fail(.malformed_end_tag, .invalid_xml);
                        }
                        self.consumeByte('>');
                        try self.finishEndElement();
                    },
                    .release_closed_element => {
                        self.releaseTopElement();
                        self.vertical_state = if (self.open_elements.items.len == 0)
                            .after_root
                        else
                            .content;
                    },
                    .reference_start => if (try self.readReferenceStart()) {
                        return self.needInput();
                    },
                    .reference_numeric_prefix => if (try self.readReferenceNumericPrefix()) {
                        return self.needInput();
                    },
                    .reference_numeric => if (try self.readReferenceNumeric()) {
                        return self.needInput();
                    },
                    .reference_entity => if (try self.readReferenceEntity()) {
                        return self.needInput();
                    },
                    .emit_text => {
                        try self.checkTextNormalization();
                        if (comptime config.profile.dtdMode() == .validating) {
                            try self.validateTextFragment();
                        }
                        self.vertical_state = .release_text;
                        return self.eventStep(
                            .{ .text = self.textEvent() },
                            self.text_start,
                            self.currentLocation(),
                        );
                    },
                    .release_text => {
                        self.text_fragment = &.{};
                        self.vertical_state = self.text_resume;
                    },
                    .markup_declaration_start => if (try self.readMarkupDeclarationStart()) {
                        return self.needInput();
                    },
                    .comment_open => if (try self.readFixedDelimiter("--", .malformed_comment)) {
                        self.vertical_state = .comment;
                    } else return self.needInput(),
                    .comment => if (try self.readComment()) return self.needInput(),
                    .comment_after_carriage_return => if (try self.readCommentCarriageReturn()) {
                        return self.needInput();
                    },
                    .emit_comment => {
                        self.vertical_state = .release_comment;
                        return self.eventStep(
                            .{ .comment = .{
                                .bytes = self.text_fragment,
                                .complete = self.fragment_complete,
                            } },
                            self.text_start,
                            self.currentLocation(),
                        );
                    },
                    .release_comment => {
                        self.text_fragment = &.{};
                        self.vertical_state = if (self.fragment_complete)
                            self.contextResumeState()
                        else
                            .comment;
                    },
                    .cdata_open => if (try self.readFixedDelimiter(
                        "[CDATA[",
                        .malformed_cdata,
                    )) {
                        if (self.markup_context != .content) {
                            return self.failAt(.malformed_cdata, .invalid_xml, self.token_start);
                        }
                        self.resetConstructNormalization();
                        self.vertical_state = .cdata;
                    } else return self.needInput(),
                    .cdata => if (try self.readCdata()) return self.needInput(),
                    .cdata_after_carriage_return => if (try self.readCdataCarriageReturn()) {
                        return self.needInput();
                    },
                    .doctype_open => if (try self.readFixedDelimiter(
                        "DOCTYPE",
                        .malformed_markup_declaration,
                    )) {
                        if (self.markup_context == .prolog) {
                            if (comptime config.profile.dtdMode() == .rejected) {
                                return self.failAt(
                                    .dtd_forbidden,
                                    .unsupported_feature,
                                    self.token_start,
                                );
                            } else {
                                if (self.dtd_state.seen_doctype) {
                                    return self.failAt(.malformed_doctype, .invalid_dtd, self.token_start);
                                }
                                self.dtd_state.declarations.clearRetainingCapacity();
                                self.dtd_state.document_type_emitted = false;
                                self.dtd_state.bracket_depth = 0;
                                self.dtd_state.lexical_state = .normal;
                                self.dtd_state.doctype_data_start = self.currentLocation();
                                self.vertical_state = .doctype;
                                continue;
                            }
                        }
                        return self.failAt(.misplaced_doctype, .invalid_xml, self.token_start);
                    } else return self.needInput(),
                    .doctype => if (try self.readDoctype()) return self.needInput(),
                    .emit_document_type => {
                        if (comptime config.profile.dtdMode() == .rejected) unreachable;
                        self.vertical_state = if (self.dtd_state.seen_doctype)
                            .finish_doctype
                        else
                            .doctype;
                        return self.eventStep(
                            .{ .document_type = self.documentType() },
                            self.token_start,
                            self.currentLocation(),
                        );
                    },
                    .finish_doctype => try self.finishDoctype(),
                    .emit_dtd_report => {
                        if (comptime config.profile.dtdMode() == .rejected) unreachable;
                        if (self.nextDtdReport()) |step| {
                            return step;
                        } else {
                            self.vertical_state = .before_root;
                        }
                    },
                    .emit_entity_start => {
                        if (comptime config.report != .detailed) unreachable;
                        self.vertical_state = .content;
                        return self.eventStep(
                            .{ .entity_start = .{ .name = self.pendingEntityName() } },
                            self.reference_start,
                            self.reference_start,
                        );
                    },
                    .emit_entity_end => {
                        if (comptime config.report != .detailed) unreachable;
                        self.vertical_state = .content;
                        return self.eventStep(
                            .{ .entity_end = .{ .name = self.pendingEntityName() } },
                            self.reference_start,
                            self.reference_start,
                        );
                    },
                    .emit_skipped_entity => {
                        if (comptime config.profile.dtdMode() == .rejected) unreachable;
                        if (comptime config.profile.dtdMode() == .validating) {
                            self.validation_incomplete = true;
                            if (self.open_elements.items.len != 0) {
                                self.open_elements.items[
                                    self.open_elements.items.len - 1
                                ].validation.content_incomplete = true;
                            }
                        }
                        self.vertical_state = .content;
                        const entity_index = self.dtd_state.pending_skipped_entity_index;
                        self.dtd_state.pending_skipped_entity_index = null;
                        const declaration = if (entity_index) |index|
                            self.dtd_state.declarations.entities.items[index]
                        else
                            null;
                        return self.eventStep(
                            .{ .skipped_entity = .{
                                .name = if (declaration) |entity|
                                    self.dtd_state.declarations.string(entity.name)
                                else
                                    self.dtd_state.reference_name.items,
                                .kind = .general_entity,
                                .public_id = if (declaration) |entity|
                                    if (entity.external_id.public_id) |value|
                                        self.dtd_state.declarations.string(value)
                                    else
                                        null
                                else
                                    null,
                                .system_id = if (declaration) |entity|
                                    if (entity.external_id.system_id) |value|
                                        self.dtd_state.declarations.string(value)
                                    else
                                        null
                                else
                                    null,
                                .reference = self.reference_start,
                            } },
                            self.reference_start,
                            self.reference_start,
                        );
                    },
                    .processing_instruction_target => if (try self.readProcessingInstructionTarget()) {
                        return self.needInput();
                    },
                    .processing_instruction_after_target => if (try self.readProcessingInstructionAfterTarget()) {
                        return self.needInput();
                    },
                    .processing_instruction_before_data => if (try self.readProcessingInstructionBeforeData()) {
                        return self.needInput();
                    },
                    .processing_instruction => if (try self.readProcessingInstruction()) {
                        return self.needInput();
                    },
                    .processing_instruction_after_carriage_return => if (try self.readProcessingInstructionCarriageReturn()) {
                        return self.needInput();
                    },
                    .emit_processing_instruction => {
                        self.vertical_state = .release_processing_instruction;
                        return self.eventStep(
                            .{ .processing_instruction = .{
                                .target = self.processingInstructionTarget(),
                                .data = self.text_fragment,
                                .complete = self.fragment_complete,
                            } },
                            self.text_start,
                            self.currentLocation(),
                        );
                    },
                    .release_processing_instruction => {
                        self.text_fragment = &.{};
                        if (self.fragment_complete) {
                            self.clearAttributesRetainingCapacity();
                            self.vertical_state = self.contextResumeState();
                        } else {
                            self.vertical_state = .processing_instruction;
                        }
                    },
                    .declaration => if (try self.readDeclaration()) return self.needInput(),
                    .declaration_question => if (try self.readDeclarationQuestion()) {
                        return self.needInput();
                    },
                    .finish_validation => {
                        try self.finishValidation();
                        self.vertical_state = .emit_document_end;
                    },
                    .emit_document_end => {
                        try self.finishNormalization();
                        self.vertical_state = .complete;
                        const location = self.currentLocation();
                        return self.eventStep(
                            .{ .document_end = self.documentEnd() },
                            location,
                            location,
                        );
                    },
                    .complete => {
                        self.lifecycle = .done;
                        return .done;
                    },
                }
            }
        }

        /// Returns the first sticky diagnostic, if one exists.
        pub fn diagnostic(self: *const Self) ?Diagnostic(config) {
            return self.first_diagnostic;
        }

        /// Returns XML 1.1 full-normalization progress or the final result.
        pub fn normalizationResult(self: *const Self) NormalizationResult(config) {
            if (comptime config.profile.isXml11()) {
                return .{
                    .status = self.normalization_status,
                    .issue = self.normalization_issue,
                };
            }
            return .{};
        }

        /// Reports memory currently owned by the reader.
        pub fn memoryUsage(self: *const Self) MemoryUsage {
            return .{
                .parser_stack_len = self.open_elements.items.len,
                .parser_stack_capacity = self.open_elements.capacity,
                .open_name_bytes = self.open_names.items.len,
                .open_name_capacity = self.open_names.capacity,
                .attribute_count = self.attribute_records.items.len,
                .attribute_record_capacity = self.attribute_records.capacity,
                .attribute_event_capacity = self.event_attributes.capacity,
                .attribute_bytes = if (self.attribute_records.items.len == 0)
                    0
                else
                    self.attribute_bytes.items.len,
                .scratch_bytes = self.attribute_bytes.items.len +|
                    self.declaration_source_advances.items.len,
                .scratch_capacity = self.attribute_bytes.capacity +|
                    self.declaration_source_advances.capacity,
                .decoder_capacity = self.decoderCapacity(),
                .namespace_capacity = self.namespaceCapacity(),
                .namespace_binding_count = self.namespaceBindingCount(),
                .namespace_bytes = self.namespaceBytes(),
                .dtd_capacity = self.dtdCapacity(),
                .notation_capacity = self.notationCapacity(),
                .validation_capacity = self.validationCapacity(),
                .content_model_capacity = self.contentModelCapacity(),
                .identity_capacity = self.identityCapacity(),
                .id_count = self.idCount(),
                .idref_count = self.idrefCount(),
                .identity_bytes = self.identityBytes(),
                .id_capacity = self.idCapacity(),
                .idref_capacity = self.idrefCapacity(),
                .id_index_capacity = self.idIndexCapacity(),
                .retained_capacity = self.retainedCapacity(),
            };
        }

        fn retainedCapacity(self: *const Self) usize {
            const stack_bytes = self.open_elements.capacity *| @sizeOf(OpenElementFrame(config));
            const record_bytes = self.attribute_records.capacity *| @sizeOf(AttributeRecord(config));
            const event_bytes = self.event_attributes.capacity *| @sizeOf(Attribute(config));
            return stack_bytes +|
                self.open_names.capacity +|
                record_bytes +|
                self.attribute_bytes.capacity +|
                self.declaration_source_advances.capacity +|
                event_bytes +|
                self.namespaceCapacity() +|
                self.dtdCapacity() +|
                self.validationCapacity() +|
                self.decoderCapacity();
        }

        fn validationCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.capacity();
        }

        fn contentModelCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.contentModelCapacity();
        }

        fn identityCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.identityCapacity();
        }

        fn notationCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() == .rejected) return 0;
            return self.dtd_state.declarations.notationCapacity();
        }

        fn idCount(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.idCount();
        }

        fn idrefCount(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.idrefCount();
        }

        fn identityBytes(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.identityBytes();
        }

        fn idCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.idCapacity();
        }

        fn idrefCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.idrefCapacity();
        }

        fn idIndexCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() != .validating) return 0;
            return self.validation_state.idIndexCapacity();
        }

        fn decoderCapacity(self: *const Self) usize {
            if (comptime config.profile.isUtf8Only()) return 0;
            var total = self.source_state.decoded.capacity +|
                self.source_state.source_advances.capacity;
            if (comptime hasTranscoderState(config)) {
                total +|= self.source_state.external.raw.capacity;
            }
            if (comptime config.external_sources) {
                for (self.dtd_state.entity_sources.items) |frame| {
                    if (!frame.external) continue;
                    total +|= frame.source_state.decoded.capacity +|
                        frame.source_state.source_advances.capacity +|
                        frame.source_state.external.raw.capacity;
                }
            }
            return total;
        }

        fn namespaceCapacity(self: *const Self) usize {
            if (comptime !config.profile.hasNamespaces()) return 0;
            return self.namespace_state.bindings.capacity *| @sizeOf(NamespaceBinding) +|
                self.namespace_state.active_prefixes.capacity *| @sizeOf(usize) +|
                self.namespace_state.bytes.capacity +|
                self.namespace_state.event_declarations.capacity *| @sizeOf(NamespaceDeclaration) +|
                self.namespace_state.expanded_indices.capacity *| @sizeOf(usize) +|
                self.namespace_state.event_attribute_locations.capacity *| @sizeOf(Location(config));
        }

        fn namespaceBindingCount(self: *const Self) usize {
            if (comptime !config.profile.hasNamespaces()) return 0;
            return self.namespace_state.bindings.items.len;
        }

        fn dtdCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() == .rejected) return 0;
            return self.dtd_state.declarations.capacity() +|
                self.dtd_state.entity_sources.capacity *| @sizeOf(EntitySourceFrame(config)) +|
                self.dtd_state.attribute_sources.capacity *| @sizeOf(AttributeEntityFrame) +|
                self.dtd_state.reference_name.capacity +|
                if (comptime config.external_sources)
                    self.dtd_state.external_source_ids.capacity *| @sizeOf(u32) +|
                        self.dtd_state.external_buffers.capacity *| @sizeOf(ExternalBuffer) +|
                        self.externalBufferCapacity() +|
                        self.diagnostic_inclusions.capacity *| @sizeOf(Location(config))
                else
                    0;
        }

        fn externalBufferCapacity(self: *const Self) usize {
            if (comptime config.profile.dtdMode() == .rejected or !config.external_sources) return 0;
            var total: usize = 0;
            for (self.dtd_state.external_buffers.items) |buffer| {
                total +|= buffer.bytes.len +|
                    buffer.source_advances.len *| @sizeOf(u32);
                if (buffer.base_id) |base_id| total +|= base_id.len;
            }
            return total;
        }

        fn namespaceBytes(self: *const Self) usize {
            if (comptime !config.profile.hasNamespaces()) return 0;
            return self.namespace_state.bytes.items.len;
        }

        fn releaseStorage(self: *Self) void {
            self.open_elements.deinit(self.allocator);
            self.open_names.deinit(self.allocator);
            self.attribute_records.deinit(self.allocator);
            self.attribute_bytes.deinit(self.allocator);
            self.declaration_source_advances.deinit(self.allocator);
            self.event_attributes.deinit(self.allocator);
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.bindings.deinit(self.allocator);
                self.namespace_state.active_prefixes.deinit(self.allocator);
                self.namespace_state.bytes.deinit(self.allocator);
                self.namespace_state.event_declarations.deinit(self.allocator);
                self.namespace_state.expanded_indices.deinit(self.allocator);
                self.namespace_state.event_attribute_locations.deinit(self.allocator);
            }
            if (comptime !config.profile.isUtf8Only()) {
                self.deinitSourceState(&self.source_state);
            }
            if (comptime config.profile.dtdMode() != .rejected) {
                self.releaseEntitySources();
                if (comptime config.external_sources) self.freeExternalBuffers();
                self.dtd_state.declarations.deinit(self.allocator);
                self.dtd_state.entity_sources.deinit(self.allocator);
                self.dtd_state.attribute_sources.deinit(self.allocator);
                self.dtd_state.reference_name.deinit(self.allocator);
                if (comptime config.external_sources) {
                    self.dtd_state.external_source_ids.deinit(self.allocator);
                    self.dtd_state.external_buffers.deinit(self.allocator);
                }
            }
            if (comptime config.profile.dtdMode() == .validating) {
                self.validation_state.deinit(self.allocator);
            }
            if (comptime config.external_sources) {
                self.diagnostic_inclusions.deinit(self.allocator);
            }
            self.open_elements = .empty;
            self.open_names = .empty;
            self.attribute_records = .empty;
            self.attribute_bytes = .empty;
            self.declaration_source_advances = .empty;
            self.event_attributes = .empty;
            self.namespace_state = .{};
            self.source_state = .{};
            self.dtd_state = .{};
            if (comptime config.profile.dtdMode() == .validating) {
                self.validation_state = .{};
            }
            self.diagnostic_inclusions = if (config.external_sources) .empty else {};
        }

        fn resetSourceStateRetainingCapacity(self: *Self) void {
            if (comptime config.profile.isUtf8Only()) return;
            self.source_state.raw_input = &.{};
            self.source_state.raw_cursor = 0;
            self.source_state.raw_final = false;
            self.source_state.raw_offset = 0;
            self.source_state.encoding = null;
            self.source_state.signature_bytes = @splat(0);
            self.source_state.signature_len = 0;
            self.source_state.decoded.clearRetainingCapacity();
            self.source_state.source_advances.clearRetainingCapacity();
            self.source_state.input_is_direct_utf8 = false;
            if (comptime config.profile.isXml11()) self.source_state.line_pending_len = 0;
            self.source_state.pending_byte = null;
            self.source_state.pending_byte_offset = 0;
            self.source_state.high_surrogate = null;
            self.source_state.high_surrogate_offset = 0;
            self.source_state.failure = null;
            if (comptime config.profile.isXml11()) {
                self.source_state.normalization.reset();
            }
            if (comptime hasTranscoderState(config)) {
                self.source_state.external.raw.clearRetainingCapacity();
                self.source_state.external.transcoder = null;
                self.source_state.external.needs_input = false;
                self.source_state.external.finished = false;
                self.source_state.external.eof = false;
                self.source_state.external.at_start = true;
            }
        }

        fn clearAttributesRetainingCapacity(self: *Self) void {
            self.attribute_records.clearRetainingCapacity();
            self.attribute_bytes.clearRetainingCapacity();
            self.declaration_source_advances.clearRetainingCapacity();
            self.event_attributes.clearRetainingCapacity();
            self.attribute_quote = 0;
            self.declaration_question_advance = 0;
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.event_declarations.clearRetainingCapacity();
                self.namespace_state.expanded_indices.clearRetainingCapacity();
                self.namespace_state.event_attribute_locations.clearRetainingCapacity();
                self.namespace_state.comparison_work = 0;
                self.namespace_state.reference_colon = null;
            }
        }

        fn clearNamespacesRetainingCapacity(self: *Self) void {
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.bindings.clearRetainingCapacity();
                self.namespace_state.active_prefixes.clearRetainingCapacity();
                self.namespace_state.bytes.clearRetainingCapacity();
                self.namespace_state.event_declarations.clearRetainingCapacity();
                self.namespace_state.expanded_indices.clearRetainingCapacity();
                self.namespace_state.event_attribute_locations.clearRetainingCapacity();
                self.namespace_state.comparison_work = 0;
                self.namespace_state.reference_colon = null;
            }
        }

        fn clearDtdRetainingCapacity(self: *Self) void {
            if (comptime config.profile.dtdMode() != .rejected) {
                self.releaseEntitySources();
                if (comptime config.external_sources) self.freeExternalBuffers();
                self.dtd_state.declarations.clearRetainingCapacity();
                self.dtd_state.entity_sources.clearRetainingCapacity();
                self.dtd_state.attribute_sources.clearRetainingCapacity();
                self.dtd_state.reference_name.clearRetainingCapacity();
                self.dtd_state.source_id = 0;
                if (comptime config.external_sources) {
                    self.dtd_state.external_resource_count = 0;
                    self.dtd_state.external_resource_bytes = 0;
                    self.dtd_state.external_source_ids.clearRetainingCapacity();
                    self.dtd_state.external_failure_code = null;
                    self.dtd_state.external_failure_location = null;
                    self.dtd_state.active_external_inclusion = null;
                }
                self.dtd_state.report_cursor = 0;
                self.dtd_state.pending_skipped_entity_index = null;
                self.dtd_state.document_type_emitted = false;
                self.dtd_state.seen_doctype = false;
                self.dtd_state.bracket_depth = 0;
                self.dtd_state.lexical_state = .normal;
            }
        }

        fn freeExternalBuffers(self: *Self) void {
            if (comptime config.profile.dtdMode() == .rejected or !config.external_sources) return;
            for (self.dtd_state.external_buffers.items) |buffer| {
                self.allocator.free(buffer.bytes);
                self.allocator.free(buffer.source_advances);
                if (buffer.base_id) |base_id| self.allocator.free(base_id);
            }
            self.dtd_state.external_buffers.clearRetainingCapacity();
        }

        fn deinitSourceState(self: *Self, source: *SourceState(config)) void {
            if (comptime config.profile.isUtf8Only()) return;
            source.decoded.deinit(self.allocator);
            source.source_advances.deinit(self.allocator);
            if (comptime hasTranscoderState(config)) {
                source.external.raw.deinit(self.allocator);
            }
            source.* = .{};
        }

        fn releaseEntitySources(self: *Self) void {
            if (comptime config.profile.dtdMode() == .rejected) return;
            if (comptime config.external_sources) {
                if (self.dtd_state.active_external) |source| source.close();
                self.dtd_state.active_external = null;
                self.dtd_state.active_external_inclusion = null;
            }
            for (self.dtd_state.entity_sources.items) |*frame| {
                if (comptime config.external_sources) {
                    if (frame.active_external) |source| source.close();
                    if (frame.external) self.deinitSourceState(&frame.source_state);
                }
            }
            self.dtd_state.entity_sources.clearRetainingCapacity();
        }

        fn documentStart(self: *const Self) DocumentStart {
            const bytes = self.attribute_bytes.items;
            return .{
                .effective_version = if (comptime config.profile.isXml11())
                    self.effective_version
                else
                    .xml10,
                .source_encoding = self.source_encoding,
                .declared_version = if (self.declared_version_len == 0)
                    null
                else
                    bytes[self.declared_version_offset..][0..self.declared_version_len],
                .declared_encoding = if (self.declared_encoding_len == 0)
                    null
                else
                    bytes[self.declared_encoding_offset..][0..self.declared_encoding_len],
                .standalone = self.standalone,
                .standalone_declared = self.standalone_declared,
            };
        }

        inline fn xmlVersion(self: *const Self) XmlVersion {
            return if (comptime config.profile.isXml11()) self.effective_version else .xml10;
        }

        fn activateNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) unreachable;
            if (self.options.normalization == .unchecked or self.xmlVersion() != .xml11) return;
            self.normalization_status = .checking;
            try self.mergeSourceNormalization();
        }

        fn finishNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            if (self.normalization_status == .unchecked) return;
            try self.mergeSourceNormalization();
            try self.enforceNormalization();
            if (self.normalization_status == .checking) self.normalization_status = .normalized;
        }

        fn mergeSourceNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) unreachable;
            const normalization = &self.source_state.normalization;
            while (true) {
                const issue = if (!normalization.issue_reported)
                    normalization.issue
                else if (!normalization.definite_issue_reported)
                    normalization.definite_issue
                else
                    null;
                const finding = issue orelse return;
                if (self.source_byte_offset <= finding.byte_offset) return;
                if (!normalization.issue_reported) {
                    normalization.issue_reported = true;
                    if (finding.kind != .unknown_character) {
                        normalization.definite_issue_reported = true;
                    }
                } else {
                    normalization.definite_issue_reported = true;
                }
                var location = locationFromSource(config, self.dtdSourceId(), finding.byte_offset);
                if (config.diagnostic_location == .line_column) {
                    location.line = finding.line;
                    location.byte_column = finding.byte_column;
                }
                try self.noteNormalization(finding.kind, location);
            }
        }

        fn noteNormalization(
            self: *Self,
            kind: NormalizationIssueKind,
            location: Location(config),
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) unreachable;
            self.recordNormalization(kind, location);
            try self.enforceNormalization();
        }

        fn recordNormalization(
            self: *Self,
            kind: NormalizationIssueKind,
            location: Location(config),
        ) void {
            if (comptime !config.profile.isXml11()) unreachable;
            if (self.normalization_status == .unchecked) return;
            const definite = kind != .unknown_character;
            if (self.normalization_issue == null or
                (definite and self.normalization_issue.?.kind == .unknown_character))
            {
                self.normalization_issue = .{
                    .kind = kind,
                    .location = location,
                };
            }
            if (definite) {
                self.normalization_status = .not_normalized;
            } else if (self.normalization_status != .not_normalized) {
                self.normalization_status = .indeterminate;
            }
        }

        fn enforceNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            if (self.options.normalization != .require) return;
            const issue = self.normalization_issue orelse return;
            return self.failAt(
                if (issue.kind == .unknown_character)
                    .normalization_properties_unknown
                else
                    .not_fully_normalized,
                .not_normalized,
                issue.location,
            );
        }

        fn scanSourceScalar(
            self: *Self,
            codepoint: u21,
            byte_offset: u64,
            source_width: u64,
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            const normalization = &self.source_state.normalization;
            if (normalization.definite_issue != null) return;
            const line = normalization.line;
            const byte_column = normalization.byte_column;
            const issue = normalization.checker.add(codepoint);
            advanceSourceNormalization(normalization, codepoint, source_width);
            const finding = issue orelse return;
            const kind: NormalizationIssueKind = switch (finding) {
                .not_nfc => .not_nfc,
                .unknown_character => .unknown_character,
            };
            const source_issue: SourceNormalizationIssue = .{
                .kind = kind,
                .byte_offset = byte_offset,
                .line = line,
                .byte_column = byte_column,
            };
            if (normalization.issue == null) normalization.issue = source_issue;
            if (kind != .unknown_character) normalization.definite_issue = source_issue;
            if (kind == .unknown_character) normalization.checker.reset();
        }

        fn scanSourceUtf8Byte(
            self: *Self,
            byte: u8,
            byte_offset: u64,
            source_advance: u64,
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            const normalization = &self.source_state.normalization;
            if (normalization.utf8_len == 0) {
                if (byte < 0x80) {
                    try self.scanSourceScalar(byte, byte_offset, source_advance);
                    return;
                }
                normalization.utf8_expected_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
                if (normalization.utf8_expected_len == 0) return;
                normalization.utf8_bytes[0] = byte;
                normalization.utf8_len = 1;
                normalization.utf8_start_offset = byte_offset;
                normalization.utf8_source_width = source_advance;
                return;
            }
            if (byte & 0xc0 != 0x80) {
                normalization.utf8_len = 0;
                normalization.utf8_expected_len = 0;
                normalization.utf8_source_width = 0;
                try self.scanSourceUtf8Byte(byte, byte_offset, source_advance);
                return;
            }
            normalization.utf8_bytes[normalization.utf8_len] = byte;
            normalization.utf8_len += 1;
            normalization.utf8_source_width += source_advance;
            if (normalization.utf8_len != normalization.utf8_expected_len) return;
            const bytes = normalization.utf8_bytes[0..normalization.utf8_len];
            const codepoint = std.unicode.utf8Decode(bytes) catch {
                normalization.utf8_len = 0;
                normalization.utf8_expected_len = 0;
                return;
            };
            const start = normalization.utf8_start_offset;
            const source_width = normalization.utf8_source_width;
            normalization.utf8_len = 0;
            normalization.utf8_expected_len = 0;
            normalization.utf8_source_width = 0;
            try self.scanSourceScalar(codepoint, start, source_width);
        }

        fn scanSourceRawUtf8Byte(self: *Self, byte: u8, byte_offset: u64) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            const normalization = &self.source_state.normalization;
            if (byte_offset < normalization.scanned_raw_offset) return;
            normalization.scanned_raw_offset = byte_offset + 1;
            try self.scanSourceUtf8Byte(byte, byte_offset, 1);
        }

        fn dtdSourceId(self: *const Self) u32 {
            if (comptime config.profile.dtdMode() == .rejected) return 0;
            return self.dtd_state.source_id;
        }

        fn resetConstructNormalization(self: *Self) void {
            if (comptime !config.profile.isXml11()) return;
            self.construct_checker.reset();
            self.construct_started = false;
            self.cdata_started = false;
        }

        fn markContentMarkup(self: *Self) void {
            if (comptime !config.profile.isXml11()) return;
            if (self.normalization_status == .unchecked) return;
            if (self.open_elements.items.len != 0) {
                self.open_elements.items[
                    self.open_elements.items.len - 1
                ].normalization_content_started = true;
            }
            self.resetConstructNormalization();
        }

        fn checkComposingStart(
            self: *Self,
            codepoint: u21,
            location: Location(config),
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            if (unicode_normalization.isComposing(codepoint)) |composing| {
                if (composing) {
                    try self.noteNormalization(.composing_start, location);
                }
            } else {
                try self.noteNormalization(.unknown_character, location);
            }
        }

        fn checkConstructNormalization(
            self: *Self,
            bytes: []const u8,
            location: Location(config),
            check_start: bool,
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            if (self.normalization_status == .unchecked or bytes.len == 0) return;
            var checker: unicode_normalization.Checker = .{};
            var view = std.unicode.Utf8View.initUnchecked(bytes);
            var iterator = view.iterator();
            var first = true;
            while (iterator.nextCodepoint()) |codepoint| {
                if (first and check_start) {
                    try self.checkComposingStart(codepoint, location);
                }
                first = false;
                if (checker.add(codepoint)) |issue| {
                    try self.noteNormalization(
                        switch (issue) {
                            .not_nfc => .not_nfc,
                            .unknown_character => .unknown_character,
                        },
                        location,
                    );
                    if (issue == .not_nfc) return;
                    checker.reset();
                }
            }
        }

        fn checkTextNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            if (self.normalization_status == .unchecked or self.text_fragment.len == 0) return;
            var view = std.unicode.Utf8View.initUnchecked(self.text_fragment);
            var iterator = view.iterator();
            var first = true;
            while (iterator.nextCodepoint()) |codepoint| {
                if (first) {
                    first = false;
                    var check_start = false;
                    if (self.open_elements.items.len != 0) {
                        const frame = &self.open_elements.items[
                            self.open_elements.items.len - 1
                        ];
                        if (!frame.normalization_content_started) {
                            frame.normalization_content_started = true;
                            check_start = true;
                        }
                    }
                    if (self.text_origin == .cdata) {
                        if (!self.cdata_started) {
                            self.cdata_started = true;
                            check_start = true;
                        }
                    } else if (!self.text_from_reference and !self.construct_started) {
                        self.construct_started = true;
                        check_start = true;
                    }
                    if (check_start) try self.checkComposingStart(codepoint, self.text_start);
                }
                if (self.construct_checker.add(codepoint)) |issue| {
                    try self.noteNormalization(
                        switch (issue) {
                            .not_nfc => .not_nfc,
                            .unknown_character => .unknown_character,
                        },
                        self.text_start,
                    );
                    if (issue == .not_nfc) return;
                    self.construct_checker.reset();
                }
            }
        }

        fn checkNormalizationTokens(
            self: *Self,
            bytes: []const u8,
            location: Location(config),
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            var tokens = SpaceTokenIterator.init(bytes);
            while (tokens.next()) |token| {
                try self.checkConstructNormalization(token, location, true);
            }
        }

        inline fn isLiteralChar(self: *const Self, codepoint: u32) bool {
            if (comptime !config.profile.isXml11()) return isXml10Char(codepoint);
            return switch (self.xmlVersion()) {
                .xml10 => isXml10Char(codepoint),
                .xml11 => isXml11Char(codepoint) and
                    (!isXml11RestrictedChar(codepoint) or
                        (comptime config.profile.dtdMode() != .rejected) and
                            self.dtd_state.current_is_replacement),
            };
        }

        inline fn isReferenceChar(self: *const Self, codepoint: u32) bool {
            if (comptime !config.profile.isXml11()) return isXml10Char(codepoint);
            return switch (self.xmlVersion()) {
                .xml10 => isXml10Char(codepoint),
                .xml11 => isXml11Char(codepoint),
            };
        }

        inline fn isXml11LineEnd(self: *const Self, codepoint: u32) bool {
            if (comptime !config.profile.isXml11()) return false;
            if (comptime config.profile.dtdMode() != .rejected) {
                if (self.dtd_state.current_is_replacement) return false;
            }
            return self.xmlVersion() == .xml11 and (codepoint == 0x85 or codepoint == 0x2028);
        }

        fn recordXml11LineEnd(self: *Self, joined_carriage_return: bool) void {
            if (config.diagnostic_location == .line_column) {
                if (!joined_carriage_return) self.position.line += 1;
                self.position.line_start_offset = self.source_byte_offset;
                self.position.pending_carriage_return = false;
            }
        }

        fn consumeNelAfterCarriageReturn(
            self: *Self,
            source: ScalarSource,
        ) ReadError!LineFollower {
            if (self.xmlVersion() != .xml11 or
                (self.utf8_len == 0 and
                    (self.cursor == self.input.len or self.input[self.cursor] < 0x80)))
            {
                return .none;
            }
            const scalar = (try self.readUtf8Scalar(source)) orelse return .need_input;
            if (scalar.codepoint != 0x85) return .none;
            self.recordXml11LineEnd(true);
            self.clearUtf8Scalar();
            return .nel;
        }

        fn contextResumeState(self: *const Self) VerticalState {
            return switch (self.markup_context) {
                .prolog => .before_root,
                .content => .content,
                .epilog => .after_root,
            };
        }

        fn beginMarkupDeclaration(self: *Self, context: MarkupContext) void {
            self.markup_context = context;
            self.delimiter_index = 0;
            self.delimiter_len = 0;
            self.vertical_state = .markup_declaration_start;
        }

        fn readDoctype(self: *Self) ReadError!bool {
            if (comptime config.profile.dtdMode() == .rejected) unreachable;
            if (self.utf8_len != 0 or
                (self.cursor < self.input.len and self.input[self.cursor] >= 0x80))
            {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, self.utf8_start);
                }
                for (self.utf8_bytes[0..scalar.len]) |byte| try self.appendDoctypeByte(byte);
                self.clearUtf8Scalar();
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failAt(.malformed_doctype, .invalid_dtd, self.token_start);
                return true;
            }
            const byte = self.input[self.cursor];
            if (!self.isLiteralChar(byte)) return self.failVoid(.forbidden_character, .invalid_xml);
            self.consumeByte(byte);
            try self.appendDoctypeByte(byte);
            if (self.dtd_state.lexical_state == .normal and
                byte == '>' and self.dtd_state.bracket_depth == 0)
            {
                self.dtd_state.seen_doctype = true;
                if (self.dtd_state.document_type_emitted) {
                    try self.finishDoctype();
                } else {
                    self.dtd_state.declarations.parseDoctypeHeader(self.allocator) catch |err|
                        return self.mapDoctypeError(err);
                    self.dtd_state.document_type_emitted = true;
                    self.vertical_state = .emit_document_type;
                }
            } else if (!self.dtd_state.document_type_emitted and
                self.dtd_state.lexical_state == .normal and
                byte == '[' and self.dtd_state.bracket_depth == 1)
            {
                self.dtd_state.declarations.parseDoctypeHeader(self.allocator) catch |err|
                    return self.mapDoctypeError(err);
                self.dtd_state.document_type_emitted = true;
                self.vertical_state = .emit_document_type;
            }
            return false;
        }

        fn finishDoctype(self: *Self) ReadError!void {
            if (comptime config.profile.dtdMode() == .rejected) {
                unreachable;
            } else {
                self.dtd_state.declarations.version = self.xmlVersion();
                self.dtd_state.declarations.discardDoctypeHeader();
                const reusable = if (comptime config.profile.dtdMode() == .validating)
                    self.options.validation.external_subset
                else
                    null;
                var appended_external: ?dtd_module.State.AppendExternalResult = null;
                if (reusable) |external| {
                    self.dtd_state.declarations.parseDoctypeInternalOnly(
                        self.allocator,
                        self.options.dtd_limits,
                    ) catch |err| return self.mapDoctypeError(err);
                    if (!external.matches(&self.dtd_state.declarations)) {
                        return self.failAt(
                            .external_subset_mismatch,
                            .invalid_dtd,
                            self.dtdLocation(0),
                        );
                    }
                    appended_external = self.dtd_state.declarations.appendExternalDeclarations(
                        self.allocator,
                        self.options.dtd_limits,
                        external.declarationState(),
                    ) catch |err| return self.mapDoctypeError(err);
                    if (comptime config.profile.isXml11()) {
                        if (external.normalizationFinding()) |finding| {
                            const position = external.sourcePosition(
                                finding.source_id,
                                @intCast(finding.byte_offset),
                            ).?;
                            var location = locationFromSource(
                                config,
                                finding.source_id,
                                finding.byte_offset,
                            );
                            if (config.diagnostic_location == .line_column) {
                                location.line = position.line;
                                location.byte_column = position.byte_column;
                            }
                            self.recordNormalization(
                                switch (finding.kind) {
                                    .not_nfc => .not_nfc,
                                    .unknown_character => .unknown_character,
                                },
                                location,
                            );
                        }
                    }
                } else if (comptime config.external_sources) {
                    self.dtd_state.declarations.parseDoctypeExternal(
                        self.allocator,
                        self.options.dtd_limits,
                        .{ .context = self, .resolveFn = dtdExternalResolve },
                    ) catch |err| return self.mapDoctypeError(err);
                } else {
                    self.dtd_state.declarations.parseDoctype(
                        self.allocator,
                        self.options.dtd_limits,
                    ) catch |err| return self.mapDoctypeError(err);
                }
                if (comptime config.profile.hasNamespaces()) {
                    try self.validateDtdNamespaceNames();
                }
                try self.checkDtdNormalization();
                try self.enforceNormalization();
                if (comptime config.profile.dtdMode() == .validating) {
                    try self.prepareValidation(reusable, appended_external);
                }
                self.dtd_state.report_cursor = 0;
                self.vertical_state = .emit_dtd_report;
            }
        }

        fn checkDtdNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11() or
                config.profile.dtdMode() == .rejected) return;
            if (self.normalization_status == .unchecked) return;
            const declarations = &self.dtd_state.declarations;
            if (declarations.root_name) |root| {
                try self.checkConstructNormalization(
                    declarations.string(root),
                    self.dtdLocation(0),
                    true,
                );
            }
            for (declarations.elements.items) |declaration| {
                const location = self.dtdSourceLocation(
                    declaration.location.source_id,
                    declaration.location.offset,
                );
                try self.checkConstructNormalization(
                    declarations.string(declaration.name),
                    location,
                    true,
                );
                if (declaration.content_spec) |content_spec| {
                    try self.checkDtdNameTokens(declarations.string(content_spec), location);
                }
            }
            for (declarations.attributes.items) |declaration| {
                const location = self.dtdSourceLocation(
                    declaration.location.source_id,
                    declaration.location.offset,
                );
                try self.checkConstructNormalization(
                    declarations.string(declaration.element_name),
                    location,
                    true,
                );
                try self.checkConstructNormalization(
                    declarations.string(declaration.name),
                    location,
                    true,
                );
                if (declaration.allowed_values) |allowed| {
                    try self.checkDtdNameTokens(declarations.string(allowed), location);
                }
                if (declaration.default_value) |default_value| {
                    const value = declarations.string(default_value);
                    try self.checkConstructNormalization(value, location, false);
                    if (declaration.attribute_type != .cdata) {
                        try self.checkNormalizationTokens(value, location);
                    }
                }
            }
            for (declarations.entities.items) |declaration| {
                const location = self.dtdSourceLocation(
                    declaration.location.source_id,
                    declaration.location.offset,
                );
                try self.checkConstructNormalization(
                    declarations.string(declaration.name),
                    location,
                    true,
                );
                if (declaration.value) |value| {
                    try self.checkConstructNormalization(
                        declarations.string(value),
                        location,
                        true,
                    );
                }
                if (declaration.notation_name) |notation_name| {
                    try self.checkConstructNormalization(
                        declarations.string(notation_name),
                        location,
                        true,
                    );
                }
            }
            for (declarations.notations.items) |declaration| {
                try self.checkConstructNormalization(
                    declarations.string(declaration.name),
                    self.dtdSourceLocation(
                        declaration.location.source_id,
                        declaration.location.offset,
                    ),
                    true,
                );
            }
            for (declarations.reports.items) |report| {
                if (report.kind != .processing_instruction) continue;
                const location = declarations.reportLocation(report).?;
                try self.checkConstructNormalization(
                    declarations.reportName(report),
                    if (location.source_id == 0)
                        self.dtdLocation(location.offset)
                    else
                        self.dtdSourceLocation(location.source_id, location.offset),
                    true,
                );
            }
        }

        fn checkDtdNameTokens(
            self: *Self,
            bytes: []const u8,
            location: Location(config),
        ) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            var view = std.unicode.Utf8View.initUnchecked(bytes);
            var iterator = view.iterator();
            var offset: usize = 0;
            var token_start: ?usize = null;
            while (iterator.nextCodepointSlice()) |scalar| {
                const codepoint = std.unicode.utf8Decode(scalar) catch unreachable;
                if (isXml10NameChar(codepoint)) {
                    if (token_start == null) token_start = offset;
                } else if (token_start) |start| {
                    try self.checkConstructNormalization(bytes[start..offset], location, true);
                    token_start = null;
                }
                offset += scalar.len;
            }
            if (token_start) |start| {
                try self.checkConstructNormalization(bytes[start..], location, true);
            }
        }

        fn prepareValidation(
            self: *Self,
            reusable: ?*const external_subset_module.ExternalSubset,
            appended: ?dtd_module.State.AppendExternalResult,
        ) ReadError!void {
            if (comptime config.external_sources) {
                self.diagnostic_inclusions.ensureTotalCapacity(
                    self.allocator,
                    self.options.dtd_limits.max_active_entity_depth,
                ) catch return self.failOutOfMemory();
            }
            for (self.dtd_state.declarations.skipped_external.items) |skipped| {
                self.validation_incomplete = true;
                self.validation_declarations_incomplete = true;
                if (skipped.kind == .parameter_entity) {
                    self.validation_parameter_entity_skipped = true;
                }
            }
            if (reusable != null and appended.?.grammar_unchanged and
                !self.validation_declarations_incomplete and
                !reusable.?.compiledState().issues_truncated)
            {
                self.validation_state.copyCompiled(
                    self.allocator,
                    self.options.validation.limits,
                    reusable.?.compiledState(),
                    appended.?.byte_base,
                ) catch |err| return self.mapValidationError(err);
            } else {
                self.validation_state.prepare(
                    self.allocator,
                    self.options.validation.limits,
                    &self.dtd_state.declarations,
                    !self.validation_declarations_incomplete,
                ) catch |err| return self.mapValidationError(err);
            }
            for (self.validation_state.issues.items) |issue| {
                try self.emitValidity(issue, self.token_start);
            }
        }

        fn mapValidationError(self: *Self, err: validation_module.Error) ReadError {
            return switch (err) {
                error.OutOfMemory => self.failOutOfMemory(),
                error.ContentPositionLimit => self.fail(
                    .validation_content_position_limit,
                    .limit_exceeded,
                ),
                error.ContentStateLimit => self.fail(
                    .validation_content_state_limit,
                    .limit_exceeded,
                ),
                error.ContentTransitionLimit => self.fail(
                    .validation_content_transition_limit,
                    .limit_exceeded,
                ),
                error.CompilationWorkLimit => self.fail(
                    .validation_compilation_work_limit,
                    .limit_exceeded,
                ),
                error.IdLimit => self.fail(.validation_id_limit, .limit_exceeded),
                error.IdrefLimit => self.fail(.validation_idref_limit, .limit_exceeded),
                error.IdentityBytesLimit => self.fail(
                    .validation_identity_bytes_limit,
                    .limit_exceeded,
                ),
                error.ComparisonWorkLimit => self.fail(
                    .validation_comparison_work_limit,
                    .limit_exceeded,
                ),
            };
        }

        fn finishValidation(self: *Self) ReadError!void {
            if (comptime config.profile.dtdMode() == .validating) {
                while (self.validation_state.unresolvedIdref(
                    self.options.validation.limits,
                    self.final_idref_cursor,
                ) catch |err| return self.mapValidationError(err)) |index| {
                    self.final_idref_cursor = index + 1;
                    const source = self.validation_state.idrefLocation(index);
                    try self.reportValidity(.{
                        .code = .unresolved_idref,
                        .occurrence = source,
                    }, validationLocation(config, source));
                }
            } else unreachable;
        }

        fn documentEnd(self: *const Self) DocumentEnd(config) {
            if (comptime config.profile.dtdMode() == .validating) {
                return .{ .validation = if (self.validity_errors != 0)
                    .invalid
                else if (self.validation_incomplete)
                    .incomplete
                else
                    .valid };
            }
            return .{};
        }

        fn dtdExternalResolve(
            context: ?*anyopaque,
            request: dtd_module.ExternalRequest,
        ) dtd_module.ParseError!dtd_module.ExternalResult {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const kind: resolver_module.EntityKind = switch (request.kind) {
                .subset => .external_subset,
                .parameter_entity => .parameter_entity,
            };
            return self.acquireExternal(
                kind,
                request.name,
                request.public_id,
                request.system_id,
                request.base_id,
                if (request.inclusion_source_id == 0)
                    self.dtdLocation(request.inclusion_offset)
                else
                    self.dtdSourceLocation(request.inclusion_source_id, request.inclusion_offset),
            );
        }

        fn acquireExternal(
            self: *Self,
            kind: resolver_module.EntityKind,
            name: ?[]const u8,
            public_id: ?[]const u8,
            system_id: []const u8,
            requested_base_id: ?[]const u8,
            inclusion: Location(config),
        ) dtd_module.ParseError!dtd_module.ExternalResult {
            const maybe_source = try self.openExternalSource(
                kind,
                name,
                public_id,
                system_id,
                requested_base_id,
                inclusion,
            );
            const source = maybe_source orelse return .skipped;
            defer source.close();

            var raw: std.ArrayList(u8) = .empty;
            defer raw.deinit(self.allocator);
            var chunk: [16 * 1024]u8 = undefined;
            while (true) switch (source.read(&chunk)) {
                .bytes => |len| {
                    if (len > self.options.resolver.max_source_bytes -| raw.items.len or
                        len > self.options.resolver.max_total_bytes -| self.dtd_state.external_resource_bytes)
                    {
                        return self.externalProviderFailure(.external_resource_bytes_limit, error.LimitExceeded);
                    }
                    raw.appendSlice(self.allocator, chunk[0..len]) catch return error.OutOfMemory;
                    self.dtd_state.external_resource_bytes += len;
                },
                .end => break,
                .io_failure => return self.externalProviderFailure(.resolver_io_failure, error.ReadFailed),
                .cancelled => return self.externalProviderFailure(.resolver_cancelled, error.Cancelled),
            };
            var decode_failure: ?ExternalDecodeFailure = null;
            const decoded = decodeExternalSource(
                self.allocator,
                raw.items,
                source.encoding_hint,
                source.transcoder,
                self.xmlVersion(),
                self.options.resolver.max_source_bytes,
                &decode_failure,
            ) catch |err| {
                if (decode_failure) |failure| {
                    self.dtd_state.external_failure_code = failure.code;
                    var location = locationFromSource(config, source.source_id, failure.byte_offset);
                    if (config.diagnostic_location == .line_column) {
                        location.line = failure.line;
                        location.byte_column = failure.byte_column;
                    }
                    self.dtd_state.external_failure_location = location;
                }
                return err;
            };
            errdefer decoded.deinit(self.allocator);
            self.checkDecodedSourceNormalization(decoded, source.source_id);
            const owned_base = if (source.base_id) |value|
                self.allocator.dupe(u8, value) catch return error.OutOfMemory
            else
                null;
            errdefer if (owned_base) |value| self.allocator.free(value);
            self.dtd_state.external_buffers.append(self.allocator, .{
                .bytes = decoded.bytes,
                .source_advances = decoded.source_advances,
                .source_start_offset = decoded.source_start_offset,
                .source_start_line = decoded.source_start_line,
                .source_start_column = decoded.source_start_column,
                .source_id = source.source_id,
                .base_id = owned_base,
                .inclusion_source_id = inclusion.source_id,
                .inclusion_offset = inclusion.byte_offset,
                .inclusion_line = if (config.diagnostic_location == .line_column) inclusion.line else 1,
                .inclusion_column = if (config.diagnostic_location == .line_column) inclusion.byte_column else 1,
            }) catch return error.OutOfMemory;
            return .{ .content = .{
                .bytes = decoded.bytes,
                .base_id = owned_base,
                .source_id = source.source_id,
            } };
        }

        fn checkDecodedSourceNormalization(
            self: *Self,
            decoded: DecodedExternalSource,
            source_id: u32,
        ) void {
            if (comptime !config.profile.isXml11()) return;
            if (self.normalization_status == .unchecked) return;
            var normalization: SourceNormalization = .{
                .line = decoded.source_start_line,
                .byte_column = decoded.source_start_column,
            };
            var cursor: usize = 0;
            var source_offset = decoded.source_start_offset;
            while (cursor < decoded.bytes.len) {
                const scalar = switch (probeUtf8(decoded.bytes[cursor..])) {
                    .scalar => |value| value,
                    .incomplete, .invalid => unreachable,
                };
                const scalar_offset = source_offset;
                var source_width: u64 = 0;
                for (decoded.source_advances[cursor..][0..scalar.len]) |advance| {
                    source_offset += advance;
                    source_width += advance;
                }
                cursor += scalar.len;
                const line = normalization.line;
                const byte_column = normalization.byte_column;
                const issue = normalization.checker.add(@intCast(scalar.codepoint));
                advanceSourceNormalization(
                    &normalization,
                    @intCast(scalar.codepoint),
                    source_width,
                );
                if (issue) |finding| {
                    const kind: NormalizationIssueKind = switch (finding) {
                        .not_nfc => .not_nfc,
                        .unknown_character => .unknown_character,
                    };
                    var location = locationFromSource(config, source_id, scalar_offset);
                    if (config.diagnostic_location == .line_column) {
                        location.line = line;
                        location.byte_column = byte_column;
                    }
                    self.recordNormalization(kind, location);
                    if (kind == .not_nfc) return;
                    normalization.checker.reset();
                }
            }
        }

        fn openExternalSource(
            self: *Self,
            kind: resolver_module.EntityKind,
            name: ?[]const u8,
            public_id: ?[]const u8,
            system_id: []const u8,
            requested_base_id: ?[]const u8,
            inclusion: Location(config),
        ) dtd_module.ParseError!?resolver_module.Source {
            if (self.options.resolver.policy == .skip) {
                return null;
            }
            self.dtd_state.external_failure_code = null;
            self.dtd_state.external_failure_location = inclusion;
            const base_id = requested_base_id orelse self.options.resolver.document_base_id;
            if (system_id.len > self.options.resolver.max_identifier_bytes or
                (public_id != null and
                    public_id.?.len > self.options.resolver.max_identifier_bytes) or
                (base_id != null and
                    base_id.?.len > self.options.resolver.max_identifier_bytes))
            {
                return self.externalProviderFailure(
                    .external_resource_identifier_limit,
                    error.LimitExceeded,
                );
            }
            if (self.dtd_state.external_resource_count == self.options.resolver.max_resources) {
                return self.externalProviderFailure(.external_resource_count_limit, error.LimitExceeded);
            }
            self.diagnostic_inclusions.ensureTotalCapacity(
                self.allocator,
                @min(
                    self.options.dtd_limits.max_active_entity_depth,
                    self.dtd_state.external_resource_count + 1,
                ),
            ) catch return error.OutOfMemory;
            self.dtd_state.external_resource_count += 1;
            const callback = self.options.resolver.resolver.?;
            const result = callback.resolve(.{
                .kind = kind,
                .name = name,
                .public_id = public_id,
                .system_id = system_id,
                .base_id = base_id,
                .inclusion = .{
                    .source_id = inclusion.source_id,
                    .byte_offset = inclusion.byte_offset,
                },
            });
            const source = switch (result) {
                .source => |source| source,
                .not_found => return self.externalProviderFailure(.resolver_not_found, error.ResolverFailed),
                .forbidden => return self.externalProviderFailure(.resolver_forbidden, error.ResolverFailed),
                .unsupported_scheme => return self.externalProviderFailure(.resolver_unsupported_scheme, error.ResolverFailed),
                .io_failure => return self.externalProviderFailure(.resolver_io_failure, error.ResolverFailed),
                .resource_limit => return self.externalProviderFailure(.resolver_resource_limit, error.LimitExceeded),
                .cancelled => return self.externalProviderFailure(.resolver_cancelled, error.Cancelled),
            };
            const reusable_source_used = if (comptime config.profile.dtdMode() == .validating)
                if (self.options.validation.external_subset) |subset|
                    subset.hasSource(source.source_id)
                else
                    false
            else
                false;
            if (source.source_id == 0 or reusable_source_used or
                std.mem.indexOfScalar(
                    u32,
                    self.dtd_state.external_source_ids.items,
                    source.source_id,
                ) != null)
            {
                source.close();
                return self.externalProviderFailure(.resolver_invalid_result, error.ResolverFailed);
            }
            if (source.base_id != null and
                source.base_id.?.len > self.options.resolver.max_identifier_bytes)
            {
                source.close();
                return self.externalProviderFailure(
                    .external_resource_identifier_limit,
                    error.LimitExceeded,
                );
            }
            self.dtd_state.external_source_ids.append(self.allocator, source.source_id) catch {
                source.close();
                return error.OutOfMemory;
            };
            return source;
        }

        fn externalProviderFailure(
            self: *Self,
            code: DiagnosticCode,
            err: dtd_module.ParseError,
        ) dtd_module.ParseError {
            self.dtd_state.external_failure_code = code;
            return err;
        }

        fn appendDoctypeByte(self: *Self, byte: u8) ReadError!void {
            self.dtd_state.declarations.appendDoctypeByte(
                self.allocator,
                self.options.dtd_limits,
                byte,
            ) catch |err| return switch (err) {
                error.LimitExceeded => self.failAt(.dtd_bytes_limit, .limit_exceeded, self.token_start),
                error.OutOfMemory => self.failOutOfMemory(),
                else => unreachable,
            };
            const bytes = self.dtd_state.declarations.doctype_bytes.items;
            switch (self.dtd_state.lexical_state) {
                .single_quote => if (byte == '\'') {
                    self.dtd_state.lexical_state = .normal;
                },
                .double_quote => if (byte == '"') {
                    self.dtd_state.lexical_state = .normal;
                },
                .comment => if (std.mem.endsWith(u8, bytes, "-->")) {
                    self.dtd_state.lexical_state = .normal;
                },
                .pi => if (std.mem.endsWith(u8, bytes, "?>")) {
                    self.dtd_state.lexical_state = .normal;
                },
                .normal => {
                    if (std.mem.endsWith(u8, bytes, "<!--")) {
                        self.dtd_state.lexical_state = .comment;
                    } else if (std.mem.endsWith(u8, bytes, "<?")) {
                        self.dtd_state.lexical_state = .pi;
                    } else switch (byte) {
                        '\'' => self.dtd_state.lexical_state = .single_quote,
                        '"' => self.dtd_state.lexical_state = .double_quote,
                        '[' => self.dtd_state.bracket_depth += 1,
                        ']' => if (self.dtd_state.bracket_depth != 0) {
                            self.dtd_state.bracket_depth -= 1;
                        },
                        else => {},
                    }
                },
            }
        }

        fn documentType(self: *const Self) DocumentType {
            const declarations = &self.dtd_state.declarations;
            return .{
                .root_name = declarations.rootName(),
                .public_id = if (declarations.external_id.public_id) |value|
                    declarations.string(value)
                else
                    null,
                .system_id = if (declarations.external_id.system_id) |value|
                    declarations.string(value)
                else
                    null,
            };
        }

        fn mapDoctypeError(self: *Self, err: dtd_module.ParseError) ReadError {
            const external_code: ?DiagnosticCode = if (comptime config.external_sources)
                self.dtd_state.external_failure_code
            else
                null;
            const location = if (comptime config.external_sources)
                if (external_code != null)
                    self.dtd_state.external_failure_location orelse self.dtdFailureLocation()
                else
                    self.dtdFailureLocation()
            else
                self.dtdFailureLocation();
            const code = self.dtdDiagnosticCode();
            return switch (err) {
                error.InvalidDtd => self.failAt(external_code orelse code, .invalid_dtd, location),
                error.UnsupportedFeature => self.failAt(
                    external_code orelse code,
                    .unsupported_feature,
                    location,
                ),
                error.LimitExceeded => self.failAt(
                    external_code orelse code,
                    .limit_exceeded,
                    location,
                ),
                error.OutOfMemory => self.failOutOfMemory(),
                error.ResolverFailed => self.failAt(external_code orelse .resolver_io_failure, .resolver_failed, location),
                error.ReadFailed => self.failAt(external_code orelse .resolver_io_failure, .read_failed, location),
                error.Cancelled => self.failAt(external_code orelse .resolver_cancelled, .cancelled, location),
            };
        }

        fn dtdDiagnosticCode(self: *const Self) DiagnosticCode {
            const failure = self.dtd_state.declarations.failure orelse return .malformed_dtd;
            return switch (failure.code) {
                .malformed_doctype => .malformed_doctype,
                .malformed_declaration,
                .malformed_comment,
                .malformed_processing_instruction,
                => .malformed_dtd,
                .malformed_element_declaration => .malformed_element_declaration,
                .malformed_attribute_list => .malformed_attribute_list_declaration,
                .malformed_entity_declaration => .malformed_entity_declaration,
                .malformed_notation_declaration => .malformed_notation_declaration,
                .undeclared_parameter_entity => .undeclared_parameter_entity,
                .recursive_parameter_entity => .recursive_parameter_entity,
                .external_subset_unsupported => .external_resource_forbidden,
                .dtd_bytes_limit => .dtd_bytes_limit,
                .declaration_limit => .dtd_declaration_limit,
                .declaration_bytes_limit => .dtd_declaration_bytes_limit,
                .element_declaration_limit => .dtd_element_declaration_limit,
                .attribute_declaration_limit => .dtd_attribute_declaration_limit,
                .entity_declaration_limit => .dtd_entity_declaration_limit,
                .notation_declaration_limit => .dtd_notation_declaration_limit,
                .grammar_depth_limit => .dtd_grammar_depth_limit,
                .grammar_node_limit => .dtd_grammar_node_limit,
                .replacement_bytes_limit => .dtd_replacement_bytes_limit,
                .entity_depth_limit => .entity_depth_limit,
                .entity_reference_limit => .entity_reference_limit,
                .expanded_bytes_limit => .entity_expansion_limit,
                .expansion_ratio_limit => .entity_expansion_ratio_limit,
                .comparison_work_limit => .dtd_comparison_work_limit,
            };
        }

        fn dtdFailureLocation(self: *const Self) Location(config) {
            const failure = self.dtd_state.declarations.failure orelse return self.dtdLocation(0);
            if (failure.source_id != 0) {
                return self.dtdSourceLocation(failure.source_id, failure.offset);
            }
            const failure_offset = failure.offset;
            return self.dtdLocation(failure_offset);
        }

        fn dtdSourceLocation(
            self: *const Self,
            source_id: u32,
            offset: usize,
        ) Location(config) {
            if (comptime config.external_sources) {
                for (self.dtd_state.external_buffers.items) |buffer| {
                    if (buffer.source_id != source_id) continue;
                    var location = locationFromSource(
                        config,
                        source_id,
                        buffer.source_start_offset,
                    );
                    if (config.diagnostic_location == .line_column) {
                        location.line = buffer.source_start_line;
                        location.byte_column = buffer.source_start_column;
                    }
                    var cursor: usize = 0;
                    while (cursor < @min(offset, buffer.bytes.len)) {
                        const byte = buffer.bytes[cursor];
                        const source_advance = buffer.source_advances[cursor];
                        cursor += 1;
                        location.byte_offset += source_advance;
                        if (config.diagnostic_location == .line_column) {
                            if (byte == '\n') {
                                location.line += 1;
                                location.byte_column = 1;
                            } else {
                                location.byte_column += source_advance;
                            }
                        }
                    }
                    return location;
                }
                if (comptime config.profile.dtdMode() == .validating) {
                    if (self.options.validation.external_subset) |external| {
                        if (external.sourcePosition(source_id, offset)) |position| {
                            var location = locationFromSource(config, source_id, position.byte_offset);
                            if (config.diagnostic_location == .line_column) {
                                location.line = position.line;
                                location.byte_column = position.byte_column;
                            }
                            return location;
                        }
                    }
                }
            }
            return locationFromSource(config, source_id, offset);
        }

        fn dtdLocation(self: *const Self, offset: usize) Location(config) {
            var location = self.dtd_state.doctype_data_start;
            const bytes = self.dtd_state.declarations.doctype_bytes.items;
            var cursor: usize = 0;
            var pending_carriage_return = false;
            while (cursor < @min(offset, bytes.len)) {
                const len = std.unicode.utf8ByteSequenceLength(bytes[cursor]) catch 1;
                if (len > bytes.len - cursor) break;
                const codepoint = std.unicode.utf8Decode(bytes[cursor..][0..len]) catch break;
                const source_width: u64 = switch (self.source_encoding) {
                    .utf8, .other => len,
                    .utf16_le, .utf16_be => if (codepoint < 0x10000) 2 else 4,
                };
                location.byte_offset += source_width;
                if (config.diagnostic_location == .line_column) {
                    if (pending_carriage_return and codepoint == '\n') {
                        pending_carriage_return = false;
                        cursor += len;
                        continue;
                    }
                    pending_carriage_return = false;
                    if (codepoint == '\r') {
                        location.line += 1;
                        location.byte_column = 1;
                        pending_carriage_return = true;
                    } else if (codepoint == '\n') {
                        location.line += 1;
                        location.byte_column = 1;
                    } else {
                        location.byte_column += source_width;
                    }
                }
                cursor += len;
            }
            return location;
        }

        fn validateDtdNamespaceNames(self: *Self) ReadError!void {
            for (self.dtd_state.declarations.entities.items) |entity| {
                const name = self.dtd_state.declarations.string(entity.name);
                if (std.mem.indexOfScalar(u8, name, ':') != null) {
                    return self.failAt(.malformed_ncname, .invalid_dtd, self.token_start);
                }
            }
            for (self.dtd_state.declarations.notations.items) |notation| {
                const name = self.dtd_state.declarations.string(notation.name);
                if (std.mem.indexOfScalar(u8, name, ':') != null) {
                    return self.failAt(.malformed_ncname, .invalid_dtd, self.token_start);
                }
            }
        }

        fn nextDtdReport(self: *Self) ?Step(config) {
            const declarations = &self.dtd_state.declarations;
            while (self.dtd_state.report_cursor < declarations.reports.items.len) {
                const report = declarations.reports.items[self.dtd_state.report_cursor];
                self.dtd_state.report_cursor += 1;
                const payload: EventPayload(config) = switch (report.kind) {
                    .comment => .{ .comment = .{
                        .bytes = declarations.reportData(report),
                        .complete = true,
                    } },
                    .processing_instruction => .{ .processing_instruction = .{
                        .target = declarations.reportName(report),
                        .data = declarations.reportData(report),
                        .complete = true,
                    } },
                    .notation => notation: {
                        const notation = declarations.notations.items[report.index];
                        break :notation .{ .notation_declaration = .{
                            .name = declarations.string(notation.name),
                            .public_id = if (notation.external_id.public_id) |value|
                                declarations.string(value)
                            else
                                null,
                            .system_id = if (notation.external_id.system_id) |value|
                                declarations.string(value)
                            else
                                null,
                        } };
                    },
                    .unparsed_entity => unparsed: {
                        const entity = declarations.entities.items[report.index];
                        break :unparsed .{ .unparsed_entity_declaration = .{
                            .name = declarations.string(entity.name),
                            .public_id = if (entity.external_id.public_id) |value|
                                declarations.string(value)
                            else
                                null,
                            .system_id = if (entity.external_id.system_id) |value|
                                declarations.string(value)
                            else
                                null,
                            .notation_name = declarations.string(entity.notation_name.?),
                        } };
                    },
                    .element => if (comptime config.report == .detailed)
                        .{ .element_declaration = .{ .name = declarations.reportName(report) } }
                    else
                        continue,
                    .attribute_list => if (comptime config.report == .detailed)
                        .{ .attribute_list_declaration = .{ .name = declarations.reportName(report) } }
                    else
                        continue,
                    .parsed_entity => if (comptime config.report == .detailed)
                        .{ .parsed_entity_declaration = .{ .name = declarations.reportName(report) } }
                    else
                        continue,
                    .skipped_external => skipped: {
                        const external = declarations.skipped_external.items[report.index];
                        break :skipped .{ .skipped_entity = .{
                            .name = if (external.name) |value| declarations.string(value) else null,
                            .kind = switch (external.kind) {
                                .subset => .external_subset,
                                .parameter_entity => .parameter_entity,
                            },
                            .public_id = if (external.public_id) |value| declarations.string(value) else null,
                            .system_id = declarations.string(external.system_id),
                            .reference = self.dtdLocation(external.offset),
                        } };
                    },
                };
                return self.eventStep(payload, self.token_start, self.currentLocation());
            }
            return null;
        }

        fn readMarkupDeclarationStart(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const start = self.utf8_start;
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                return self.failAt(
                    .malformed_markup_declaration,
                    .invalid_xml,
                    start,
                );
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.incomplete_input, .invalid_xml);
                return true;
            }
            switch (self.input[self.cursor]) {
                '-' => {
                    if (comptime config.profile.dtdMode() == .validating) {
                        if (self.markup_context == .content) {
                            try self.noteValidationContentMarker(self.token_start);
                        }
                    }
                    self.vertical_state = .comment_open;
                },
                '[' => {
                    if (comptime config.profile.dtdMode() == .validating) {
                        if (self.markup_context == .content) {
                            try self.noteValidationContentMarker(self.token_start);
                        }
                    }
                    self.vertical_state = .cdata_open;
                },
                'D' => self.vertical_state = .doctype_open,
                else => {
                    if (self.input[self.cursor] >= 0x80) {
                        const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                        const start = self.utf8_start;
                        if (!self.isLiteralChar(scalar.codepoint)) {
                            return self.failAt(.forbidden_character, .invalid_xml, start);
                        }
                        return self.failAt(
                            .malformed_markup_declaration,
                            .invalid_xml,
                            start,
                        );
                    }
                    if (!self.isLiteralChar(self.input[self.cursor])) {
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                    return self.failVoid(.malformed_markup_declaration, .invalid_xml);
                },
            }
            return false;
        }

        fn readFixedDelimiter(
            self: *Self,
            comptime delimiter: []const u8,
            malformed_code: DiagnosticCode,
        ) ReadError!bool {
            while (self.delimiter_index < delimiter.len) {
                if (self.utf8_len != 0) {
                    const consumed = self.source_byte_offset - self.token_start.byte_offset - 1;
                    const scalar_len = self.pendingUtf8ScalarLength() catch
                        return self.failVoid(.malformed_utf8, .invalid_xml);
                    const remaining_scalar = scalar_len - self.utf8_len;
                    if (remaining_scalar > self.options.limits.max_partial_token_bytes - consumed) {
                        return self.failVoid(.partial_token_limit, .limit_exceeded);
                    }
                    const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return false;
                    const start = self.utf8_start;
                    if (!self.isLiteralChar(scalar.codepoint)) {
                        return self.failAt(.forbidden_character, .invalid_xml, start);
                    }
                    return self.failAt(malformed_code, .invalid_xml, start);
                }
                if (self.cursor == self.input.len) {
                    if (self.final_input) {
                        return self.failVoid(.incomplete_input, .invalid_xml);
                    }
                    return false;
                }
                const consumed = self.source_byte_offset - self.token_start.byte_offset - 1;
                if (consumed >= self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                const byte = self.input[self.cursor];
                if (byte >= 0x80) {
                    const scalar_len = self.pendingUtf8ScalarLength() catch
                        return self.failVoid(.malformed_utf8, .invalid_xml);
                    if (scalar_len > self.options.limits.max_partial_token_bytes - consumed) {
                        return self.failVoid(.partial_token_limit, .limit_exceeded);
                    }
                    const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return false;
                    const start = self.utf8_start;
                    if (!self.isLiteralChar(scalar.codepoint)) {
                        return self.failAt(.forbidden_character, .invalid_xml, start);
                    }
                    return self.failAt(malformed_code, .invalid_xml, start);
                }
                if (byte != delimiter[self.delimiter_index]) {
                    if (!self.isLiteralChar(byte)) {
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                    return self.failVoid(malformed_code, .invalid_xml);
                }
                self.consumeByte(byte);
                self.delimiter_index += 1;
            }
            self.delimiter_index = 0;
            self.delimiter_len = 0;
            return true;
        }

        fn beginProcessingInstruction(
            self: *Self,
            context: MarkupContext,
            initial: bool,
        ) ReadError!void {
            if (comptime config.profile.dtdMode() == .validating) {
                if (context == .content) try self.noteValidationContentMarker(self.token_start);
            }
            self.clearAttributesRetainingCapacity();
            self.markup_context = context;
            self.processing_instruction_initial = initial;
            self.processing_instruction_target_len = 0;
            self.delimiter_len = 0;
            self.vertical_state = .processing_instruction_target;
        }

        fn appendProcessingInstructionTarget(
            self: *Self,
            bytes: []const u8,
        ) ReadError!void {
            const limit = self.options.limits.max_processing_instruction_target_bytes;
            if (self.processing_instruction_target_len > limit or
                bytes.len > limit - self.processing_instruction_target_len)
            {
                return self.failProcessingInstructionTargetLimit();
            }
            self.attribute_bytes.appendSlice(self.allocator, bytes) catch
                return self.failOutOfMemory();
            self.processing_instruction_target_len += bytes.len;
        }

        fn failProcessingInstructionTargetLimit(self: *Self) ReadError {
            const target = self.processingInstructionTarget();
            const prefix_len = @min(
                target.len,
                self.options.limits.max_processing_instruction_target_bytes,
            );
            return self.failAt(
                .processing_instruction_target_limit,
                .limit_exceeded,
                self.locationWithSemanticPrefix(self.token_start, 2, target[0..prefix_len]),
            );
        }

        fn processingInstructionTarget(self: *const Self) []const u8 {
            return self.attribute_bytes.items[0..self.processing_instruction_target_len];
        }

        fn readProcessingInstructionTarget(self: *Self) ReadError!bool {
            const run_start = self.cursor;
            var run_end = run_start;
            if (self.utf8_len == 0) {
                while (run_end < self.input.len and isAsciiNameChar(self.input[run_end])) {
                    run_end += 1;
                }
            }
            if (run_end != run_start) {
                if (self.processing_instruction_target_len == 0 and
                    !isAsciiNameStart(self.input[run_start]))
                {
                    return self.failVoid(.malformed_processing_instruction, .invalid_xml);
                }
                const run = self.input[run_start..run_end];
                const target_limit = self.options.limits.max_processing_instruction_target_bytes;
                var remaining = if (self.processing_instruction_target_len < target_limit)
                    target_limit - self.processing_instruction_target_len
                else
                    0;
                if (self.processing_instruction_initial and
                    self.processing_instruction_target_len < 3)
                {
                    const target = self.processingInstructionTarget();
                    if (std.mem.eql(u8, target, "xml"[0..target.len])) {
                        var probe_len: usize = 0;
                        const probe_end = @min(run.len, 3 - target.len);
                        while (probe_len < probe_end and
                            run[probe_len] == "xml"[target.len + probe_len])
                        {
                            probe_len += 1;
                        }
                        remaining = @max(remaining, probe_len);
                    }
                }
                const accepted_len = @min(run.len, remaining);
                if (accepted_len > 0) {
                    self.attribute_bytes.appendSlice(
                        self.allocator,
                        run[0..accepted_len],
                    ) catch return self.failOutOfMemory();
                    self.processing_instruction_target_len += accepted_len;
                    self.consumeRun(run[0..accepted_len]);
                }
                if (accepted_len != run.len) {
                    return self.failProcessingInstructionTargetLimit();
                }
            }

            if (self.utf8_len != 0 and self.cursor == self.input.len) {
                _ = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                unreachable;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    if (self.processing_instruction_initial and
                        std.mem.eql(u8, self.processingInstructionTarget(), "xml"))
                    {
                        return self.failAt(
                            .incomplete_declaration,
                            .invalid_xml,
                            self.currentLocation(),
                        );
                    }
                    if (self.processing_instruction_target_len >
                        self.options.limits.max_processing_instruction_target_bytes)
                    {
                        return self.failProcessingInstructionTargetLimit();
                    }
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }
            if (self.processing_instruction_target_len >
                self.options.limits.max_processing_instruction_target_bytes and
                (!self.processing_instruction_initial or
                    !std.mem.eql(u8, self.processingInstructionTarget(), "xml") or
                    (!isXmlWhitespace(self.input[self.cursor]) and
                        self.input[self.cursor] != '?')))
            {
                return self.failProcessingInstructionTargetLimit();
            }
            if (self.utf8_len != 0 or self.input[self.cursor] >= 0x80) {
                const scalar_len = self.pendingUtf8ScalarLength() catch
                    return self.failVoid(.malformed_utf8, .invalid_xml);
                const target_limit =
                    self.options.limits.max_processing_instruction_target_bytes;
                if (self.processing_instruction_target_len > target_limit or
                    scalar_len > target_limit - self.processing_instruction_target_len)
                {
                    return self.failVoid(
                        .processing_instruction_target_limit,
                        .limit_exceeded,
                    );
                }
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const start = self.utf8_start;
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                const valid = if (self.processing_instruction_target_len == 0)
                    isXml10NameStart(scalar.codepoint)
                else
                    isXml10NameChar(scalar.codepoint);
                if (!valid) {
                    return self.failAt(
                        .malformed_processing_instruction,
                        .invalid_xml,
                        start,
                    );
                }
                try self.appendProcessingInstructionTarget(self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                return false;
            }

            if (self.processing_instruction_target_len == 0) {
                return self.failVoid(.malformed_processing_instruction, .invalid_xml);
            }
            const byte = self.input[self.cursor];
            if (!isXmlWhitespace(byte) and byte != '?') {
                if (!self.isLiteralChar(byte)) return self.failVoid(.forbidden_character, .invalid_xml);
                return self.failVoid(.malformed_processing_instruction, .invalid_xml);
            }

            const target = self.processingInstructionTarget();
            if (comptime config.profile.hasNamespaces()) {
                if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
                    return self.failAt(
                        .malformed_ncname,
                        .invalid_xml,
                        self.locationWithSemanticPrefix(
                            self.token_start,
                            2,
                            target[0..colon],
                        ),
                    );
                }
            }
            try self.checkConstructNormalization(
                target,
                self.locationWithSemanticPrefix(self.token_start, 2, ""),
                true,
            );
            if (self.processing_instruction_initial and
                std.mem.eql(u8, target, "xml") and isXmlWhitespace(byte))
            {
                const declaration_bytes =
                    self.source_byte_offset - self.token_start.byte_offset;
                const partial_limit = self.options.limits.max_partial_token_bytes;
                if (declaration_bytes > partial_limit) {
                    return self.failAt(
                        .partial_token_limit,
                        .limit_exceeded,
                        locationWithByteDelta(config, self.token_start, partial_limit),
                    );
                }
                self.clearAttributesRetainingCapacity();
                self.declaration_data_start = self.currentLocation();
                self.vertical_state = .declaration;
                return false;
            }
            if (isAsciiCaseInsensitiveXml(target)) {
                const code: DiagnosticCode = if (std.mem.eql(u8, target, "xml"))
                    .misplaced_xml_declaration
                else
                    .reserved_processing_instruction_target;
                if (self.processing_instruction_initial and byte == '?') {
                    return self.failAt(.malformed_declaration, .invalid_xml, self.token_start);
                }
                return self.failAt(code, .invalid_xml, self.token_start);
            }

            if (self.processing_instruction_initial) {
                self.document_start_span = self.token_start;
                self.document_start_resume = .processing_instruction_after_target;
                self.processing_instruction_initial = false;
                self.vertical_state = .emit_document_start;
            } else {
                self.vertical_state = .processing_instruction_after_target;
            }
            return false;
        }

        fn readProcessingInstructionAfterTarget(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }
            if (self.input[self.cursor] == '?') {
                self.vertical_state = .processing_instruction;
                return false;
            }
            std.debug.assert(isXmlWhitespace(self.input[self.cursor]));
            self.vertical_state = .processing_instruction_before_data;
            return false;
        }

        fn readProcessingInstructionBeforeData(self: *Self) ReadError!bool {
            self.consumeWhitespaceRun();
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }
            self.vertical_state = .processing_instruction;
            return false;
        }

        fn prepareCommentFragment(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
            complete: bool,
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            self.text_fragment = bytes;
            self.text_start = start;
            self.fragment_complete = complete;
            self.vertical_state = .emit_comment;
        }

        fn prepareProcessingInstructionFragment(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
            complete: bool,
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            self.text_fragment = bytes;
            self.text_start = start;
            self.fragment_complete = complete;
            self.vertical_state = .emit_processing_instruction;
        }

        fn prepareCdataFragment(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            self.text_fragment = bytes;
            self.text_start = start;
            self.text_origin = .cdata;
            self.text_from_reference = false;
            self.text_resume = .cdata;
            self.vertical_state = .emit_text;
        }

        fn readComment(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const scalar_start = self.utf8_start;
                if (self.isXml11LineEnd(scalar.codepoint)) {
                    self.recordXml11LineEnd(false);
                    self.clearUtf8Scalar();
                    try self.prepareCommentFragment("\n", scalar_start, false);
                    return false;
                }
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
                }
                @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                try self.prepareCommentFragment(
                    self.text_inline[0..scalar.len],
                    scalar_start,
                    false,
                );
                return false;
            }
            if (self.delimiter_len == 1) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_comment, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] == '-') {
                    self.consumeByte('-');
                    self.delimiter_bytes[1] = '-';
                    self.delimiter_len = 2;
                } else {
                    self.delimiter_len = 0;
                    try self.prepareCommentFragment("-", self.delimiter_start, false);
                    return false;
                }
            }
            if (self.delimiter_len == 2) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_comment, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] != '>') {
                    return self.failVoid(.malformed_comment, .invalid_xml);
                }
                self.consumeByte('>');
                self.delimiter_len = 0;
                try self.prepareCommentFragment(&.{}, self.delimiter_start, true);
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.unclosed_comment, .invalid_xml);
                return true;
            }

            const run_start = self.cursor;
            const start = self.currentLocation();
            var run_end = run_start;
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            while (run_end < fragment_end) {
                const byte = self.input[run_end];
                if (byte == '-' or byte == '\r') break;
                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (!self.isLiteralChar(byte)) {
                        if (run_end != run_start) break;
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => break,
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (self.isXml11LineEnd(scalar.codepoint)) break;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                        },
                    }
                }
                if (scalar_len > self.options.limits.max_fragment_bytes -| (run_end - run_start)) {
                    if (run_end == run_start) {
                        return self.failAt(.fragment_limit, .limit_exceeded, start);
                    }
                    break;
                }
                run_end += scalar_len;
            }
            if (run_end != run_start) {
                const fragment = self.input[run_start..run_end];
                self.consumeRun(fragment);
                try self.prepareCommentFragment(fragment, start, false);
                return false;
            }

            const byte = self.input[self.cursor];
            if (byte == '-') {
                self.delimiter_start = self.currentLocation();
                self.consumeByte('-');
                self.delimiter_bytes[0] = '-';
                self.delimiter_len = 1;
                return false;
            }
            if (byte == '\r') {
                self.text_start = self.currentLocation();
                self.consumeByte('\r');
                if (comptime config.profile.dtdMode() != .rejected) {
                    if (self.dtd_state.current_is_replacement) {
                        try self.prepareCommentFragment("\r", self.text_start, false);
                        return false;
                    }
                }
                self.vertical_state = .comment_after_carriage_return;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const scalar_start = self.utf8_start;
            if (self.isXml11LineEnd(scalar.codepoint)) {
                self.recordXml11LineEnd(false);
                self.clearUtf8Scalar();
                try self.prepareCommentFragment("\n", scalar_start, false);
                return false;
            }
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
            }
            @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            try self.prepareCommentFragment(self.text_inline[0..scalar.len], scalar_start, false);
            return false;
        }

        fn readCommentCarriageReturn(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len and !self.final_input) return true;
            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                self.consumeByte('\n');
            } else switch (try self.consumeNelAfterCarriageReturn(.ordinary)) {
                .need_input => return true,
                .none, .nel => {},
            }
            try self.prepareCommentFragment("\n", self.text_start, false);
            return false;
        }

        fn readProcessingInstruction(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const scalar_start = self.utf8_start;
                if (self.isXml11LineEnd(scalar.codepoint)) {
                    self.recordXml11LineEnd(false);
                    self.clearUtf8Scalar();
                    try self.prepareProcessingInstructionFragment("\n", scalar_start, false);
                    return false;
                }
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
                }
                @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                try self.prepareProcessingInstructionFragment(
                    self.text_inline[0..scalar.len],
                    scalar_start,
                    false,
                );
                return false;
            }
            if (self.delimiter_len == 1) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) {
                        return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                    }
                    return true;
                }
                if (self.input[self.cursor] == '>') {
                    self.consumeByte('>');
                    self.delimiter_len = 0;
                    try self.prepareProcessingInstructionFragment(
                        &.{},
                        self.delimiter_start,
                        true,
                    );
                    return false;
                }
                self.delimiter_len = 0;
                try self.prepareProcessingInstructionFragment(
                    "?",
                    self.delimiter_start,
                    false,
                );
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) {
                    return self.failVoid(.incomplete_processing_instruction, .invalid_xml);
                }
                return true;
            }

            const run_start = self.cursor;
            const start = self.currentLocation();
            var run_end = run_start;
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            while (run_end < fragment_end) {
                const byte = self.input[run_end];
                if (byte == '?' or byte == '\r') break;
                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (!self.isLiteralChar(byte)) {
                        if (run_end != run_start) break;
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => break,
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (self.isXml11LineEnd(scalar.codepoint)) break;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                        },
                    }
                }
                if (scalar_len > self.options.limits.max_fragment_bytes -| (run_end - run_start)) {
                    if (run_end == run_start) {
                        return self.failAt(.fragment_limit, .limit_exceeded, start);
                    }
                    break;
                }
                run_end += scalar_len;
            }
            if (run_end != run_start) {
                const fragment = self.input[run_start..run_end];
                self.consumeRun(fragment);
                try self.prepareProcessingInstructionFragment(fragment, start, false);
                return false;
            }

            const byte = self.input[self.cursor];
            if (byte == '?') {
                self.delimiter_start = self.currentLocation();
                self.consumeByte('?');
                self.delimiter_bytes[0] = '?';
                self.delimiter_len = 1;
                return false;
            }
            if (byte == '\r') {
                self.text_start = self.currentLocation();
                self.consumeByte('\r');
                if (comptime config.profile.dtdMode() != .rejected) {
                    if (self.dtd_state.current_is_replacement) {
                        try self.prepareProcessingInstructionFragment("\r", self.text_start, false);
                        return false;
                    }
                }
                self.vertical_state = .processing_instruction_after_carriage_return;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const scalar_start = self.utf8_start;
            if (self.isXml11LineEnd(scalar.codepoint)) {
                self.recordXml11LineEnd(false);
                self.clearUtf8Scalar();
                try self.prepareProcessingInstructionFragment("\n", scalar_start, false);
                return false;
            }
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
            }
            @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            try self.prepareProcessingInstructionFragment(
                self.text_inline[0..scalar.len],
                scalar_start,
                false,
            );
            return false;
        }

        fn readProcessingInstructionCarriageReturn(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len and !self.final_input) return true;
            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                self.consumeByte('\n');
            } else switch (try self.consumeNelAfterCarriageReturn(.ordinary)) {
                .need_input => return true,
                .none, .nel => {},
            }
            try self.prepareProcessingInstructionFragment("\n", self.text_start, false);
            return false;
        }

        fn readCdata(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const scalar_start = self.utf8_start;
                if (self.isXml11LineEnd(scalar.codepoint)) {
                    self.recordXml11LineEnd(false);
                    self.clearUtf8Scalar();
                    try self.prepareCdataFragment("\n", scalar_start);
                    return false;
                }
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
                }
                @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                try self.prepareCdataFragment(self.text_inline[0..scalar.len], scalar_start);
                return false;
            }
            if (self.delimiter_len == 1) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_cdata, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] == ']') {
                    self.consumeByte(']');
                    self.delimiter_bytes[1] = ']';
                    self.delimiter_len = 2;
                } else {
                    self.delimiter_len = 0;
                    try self.prepareCdataFragment("]", self.delimiter_start);
                    return false;
                }
            }
            if (self.delimiter_len == 2) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) return self.failVoid(.unclosed_cdata, .invalid_xml);
                    return true;
                }
                if (self.input[self.cursor] == '>') {
                    self.consumeByte('>');
                    self.delimiter_len = 0;
                    self.resetConstructNormalization();
                    self.vertical_state = .content;
                    return false;
                }
                const start = self.delimiter_start;
                self.delimiter_start = self.locationWithSemanticPrefix(start, 0, "]");
                self.delimiter_len = 1;
                try self.prepareCdataFragment("]", start);
                return false;
            }
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.unclosed_cdata, .invalid_xml);
                return true;
            }

            const run_start = self.cursor;
            const start = self.currentLocation();
            var run_end = run_start;
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            while (run_end < fragment_end) {
                const byte = self.input[run_end];
                if (byte == ']' or byte == '\r') break;
                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (!self.isLiteralChar(byte)) {
                        if (run_end != run_start) break;
                        return self.failVoid(.forbidden_character, .invalid_xml);
                    }
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => break,
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (self.isXml11LineEnd(scalar.codepoint)) break;
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                        },
                    }
                }
                if (scalar_len > self.options.limits.max_fragment_bytes -| (run_end - run_start)) {
                    if (run_end == run_start) {
                        return self.failAt(.fragment_limit, .limit_exceeded, start);
                    }
                    break;
                }
                run_end += scalar_len;
            }
            if (run_end != run_start) {
                const fragment = self.input[run_start..run_end];
                self.consumeRun(fragment);
                try self.prepareCdataFragment(fragment, start);
                return false;
            }

            const byte = self.input[self.cursor];
            if (byte == ']') {
                self.delimiter_start = self.currentLocation();
                self.consumeByte(']');
                self.delimiter_bytes[0] = ']';
                self.delimiter_len = 1;
                return false;
            }
            if (byte == '\r') {
                self.text_start = self.currentLocation();
                self.consumeByte('\r');
                if (comptime config.profile.dtdMode() != .rejected) {
                    if (self.dtd_state.current_is_replacement) {
                        try self.prepareCdataFragment("\r", self.text_start);
                        return false;
                    }
                }
                self.vertical_state = .cdata_after_carriage_return;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const scalar_start = self.utf8_start;
            if (self.isXml11LineEnd(scalar.codepoint)) {
                self.recordXml11LineEnd(false);
                self.clearUtf8Scalar();
                try self.prepareCdataFragment("\n", scalar_start);
                return false;
            }
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, scalar_start);
            }
            @memcpy(self.text_inline[0..scalar.len], self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            try self.prepareCdataFragment(self.text_inline[0..scalar.len], scalar_start);
            return false;
        }

        fn readCdataCarriageReturn(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len and !self.final_input) return true;
            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                self.consumeByte('\n');
            } else switch (try self.consumeNelAfterCarriageReturn(.ordinary)) {
                .need_input => return true,
                .none, .nel => {},
            }
            try self.prepareCdataFragment("\n", self.text_start);
            return false;
        }

        fn consumeDeclarationByte(self: *Self, byte: u8) ReadError!void {
            const consumed = self.source_byte_offset - self.token_start.byte_offset;
            if (consumed >= self.options.limits.max_partial_token_bytes) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            self.consumeByte(byte);
        }

        fn appendDeclarationByte(self: *Self, byte: u8) ReadError!void {
            self.attribute_bytes.ensureUnusedCapacity(self.allocator, 1) catch
                return self.failOutOfMemory();
            const source_advance = if (self.source_encoding == .other) advance: {
                const value = self.sourceAdvanceAt(0);
                self.declaration_source_advances.ensureUnusedCapacity(self.allocator, 1) catch
                    return self.failOutOfMemory();
                break :advance value;
            } else 0;
            try self.consumeDeclarationByte(byte);
            self.attribute_bytes.appendAssumeCapacity(byte);
            if (self.source_encoding == .other) {
                self.declaration_source_advances.appendAssumeCapacity(source_advance);
            }
        }

        fn readDeclaration(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.incomplete_declaration, .invalid_xml);
                return true;
            }
            const byte = self.input[self.cursor];
            if (byte == '?') {
                if (self.source_encoding == .other) {
                    self.declaration_question_advance = self.sourceAdvanceAt(0);
                }
                try self.consumeDeclarationByte('?');
                self.vertical_state = .declaration_question;
                return false;
            }
            if (self.utf8_len != 0 or byte >= 0x80) {
                const consumed = self.source_byte_offset - self.token_start.byte_offset;
                const limit = self.options.limits.max_partial_token_bytes;
                if (consumed >= limit) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                const scalar_len = self.pendingUtf8ScalarLength() catch
                    return self.failVoid(.malformed_utf8, .invalid_xml);
                const remaining_scalar = scalar_len - self.utf8_len;
                if (remaining_scalar > limit - consumed) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
                const start = self.utf8_start;
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                return self.failAt(.malformed_declaration, .invalid_xml, start);
            }
            if (!self.isLiteralChar(byte)) return self.failVoid(.forbidden_character, .invalid_xml);
            try self.appendDeclarationByte(byte);
            return false;
        }

        fn readDeclarationQuestion(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) {
                if (self.final_input) return self.failVoid(.incomplete_declaration, .invalid_xml);
                return true;
            }
            if (self.input[self.cursor] != '>') {
                self.attribute_bytes.ensureUnusedCapacity(self.allocator, 1) catch
                    return self.failOutOfMemory();
                if (self.source_encoding == .other) {
                    self.declaration_source_advances.ensureUnusedCapacity(self.allocator, 1) catch
                        return self.failOutOfMemory();
                }
                self.attribute_bytes.appendAssumeCapacity('?');
                if (self.source_encoding == .other) {
                    self.declaration_source_advances.appendAssumeCapacity(
                        self.declaration_question_advance,
                    );
                }
                self.declaration_question_advance = 0;
                self.vertical_state = .declaration;
                return false;
            }
            try self.consumeDeclarationByte('>');
            try self.finishDeclaration();
            self.document_start_span = self.token_start;
            self.document_start_resume = .release_document_start;
            self.vertical_state = .emit_document_start;
            return false;
        }

        fn finishDeclaration(self: *Self) ReadError!void {
            switch (parseXmlDeclaration(
                self.attribute_bytes.items,
                self.source_encoding,
                !config.profile.isUtf8Only(),
                config.profile.isXml11(),
            )) {
                .parsed => |parsed| {
                    self.declared_version_offset = parsed.version_offset;
                    self.declared_version_len = parsed.version_len;
                    self.declared_encoding_offset = parsed.encoding_offset;
                    self.declared_encoding_len = parsed.encoding_len;
                    self.standalone = parsed.standalone;
                    self.standalone_declared = parsed.standalone_declared;
                    if (comptime config.profile.isXml11()) {
                        self.effective_version = parsed.effective_version;
                        if (parsed.effective_version == .xml11) {
                            try self.activateXml11LineNormalization();
                            try self.activateNormalization();
                        }
                    }
                },
                .malformed => |index| return self.failAt(
                    .malformed_declaration,
                    .invalid_xml,
                    self.declarationLocation(index),
                ),
                .unsupported_version => |index| return self.failAt(
                    .unsupported_version,
                    .invalid_xml,
                    self.declarationLocation(index),
                ),
                .unsupported_encoding => |index| return self.failAt(
                    .unsupported_encoding,
                    .unsupported_feature,
                    self.declarationLocation(index),
                ),
                .encoding_mismatch => |index| return self.failAt(
                    .encoding_mismatch,
                    .invalid_xml,
                    self.declarationLocation(index),
                ),
            }
        }

        fn declarationLocation(self: *const Self, index: usize) Location(config) {
            var location = self.declaration_data_start;
            var pending_carriage_return = false;
            const end = @min(index, self.attribute_bytes.items.len);
            for (self.attribute_bytes.items[0..end], 0..) |byte, source_index| {
                const source_width: u64 = switch (self.source_encoding) {
                    .utf8 => 1,
                    .utf16_le, .utf16_be => 2,
                    .other => self.declaration_source_advances.items[source_index],
                };
                location.byte_offset += source_width;
                if (config.diagnostic_location == .line_column) {
                    if (pending_carriage_return and byte == '\n') {
                        location.byte_column = 1;
                        pending_carriage_return = false;
                        continue;
                    }
                    pending_carriage_return = false;
                    if (byte == '\r') {
                        location.line += 1;
                        location.byte_column = 1;
                        pending_carriage_return = true;
                    } else if (byte == '\n') {
                        location.line += 1;
                        location.byte_column = 1;
                    } else {
                        location.byte_column += source_width;
                    }
                }
            }
            return location;
        }

        fn readUtf8Scalar(self: *Self, source: ScalarSource) ReadError!?DecodedScalar {
            if (self.utf8_len == 0) {
                std.debug.assert(self.cursor < self.input.len);
                self.utf8_start = self.currentLocation();
                const lead = self.input[self.cursor];
                self.utf8_expected_len = utf8ExpectedLength(lead) orelse
                    return self.fail(.malformed_utf8, .invalid_xml);
            }

            while (self.utf8_len < self.utf8_expected_len) {
                if (self.cursor == self.input.len) {
                    if (self.final_input) {
                        return self.failAt(
                            .malformed_utf8,
                            .invalid_xml,
                            self.utf8_start,
                        );
                    }
                    return null;
                }
                const byte = self.input[self.cursor];
                const index: usize = self.utf8_len;
                if (index > 0 and (byte < 0x80 or byte > 0xbf or
                    (index == 1 and !validUtf8SecondByte(self.utf8_bytes[0], byte))))
                {
                    return self.fail(.malformed_utf8, .invalid_xml);
                }
                const source_advance = self.sourceAdvanceAt(0);
                switch (source) {
                    .ordinary => self.consumeByte(byte),
                    .start_tag => {
                        try self.requireStartTagByte();
                        self.consumeStartTagByte(byte);
                    },
                    .reference => try self.consumeReferenceByte(byte),
                }
                self.utf8_bytes[index] = byte;
                self.utf8_source_advances[index] = source_advance;
                self.utf8_len += 1;
            }

            const bytes = self.utf8_bytes[0..self.utf8_expected_len];
            const codepoint: u32 = std.unicode.utf8Decode(bytes) catch unreachable;
            return .{ .codepoint = codepoint, .len = self.utf8_expected_len };
        }

        fn clearUtf8Scalar(self: *Self) void {
            self.utf8_len = 0;
            self.utf8_expected_len = 0;
        }

        fn rejectNonAsciiMarkup(
            self: *Self,
            code: DiagnosticCode,
        ) ReadError!bool {
            const scalar = (try self.readUtf8Scalar(.ordinary)) orelse return true;
            const start = self.utf8_start;
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            return self.failAt(code, .invalid_xml, start);
        }

        fn rejectStartTagNonAsciiMarkup(
            self: *Self,
            code: DiagnosticCode,
        ) ReadError!bool {
            const scalar = (try self.readUtf8Scalar(.start_tag)) orelse return true;
            const start = self.utf8_start;
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            return self.failAt(code, .invalid_xml, start);
        }

        fn prepareContentRun(self: *Self) ReadError!bool {
            std.debug.assert(self.utf8_len == 0);
            const run_start = self.cursor;
            const start = self.currentLocation();
            const fragment_end = @min(
                self.input.len,
                run_start +| self.options.limits.max_fragment_bytes,
            );
            const candidate = self.input[run_start..fragment_end];
            if (contentHasOrdinaryPrefix(candidate) and
                self.prepareBulkContentRun(candidate, start))
            {
                return true;
            }

            var run_end = run_start;
            var close_brackets = self.text_close_brackets;
            while (run_end < fragment_end) {
                const byte = self.input[run_end];

                var scalar_len: usize = 1;
                if (byte < 0x80) {
                    if (byte == '<' or byte == '&' or byte == '\r') break;
                    if (!self.isLiteralChar(byte)) {
                        if (run_end != run_start) break;
                        return self.fail(.forbidden_character, .invalid_xml);
                    }
                    if (byte == '>' and close_brackets == 2) {
                        if (run_end != run_start) break;
                        return self.fail(.cdata_close_in_text, .invalid_xml);
                    }
                    close_brackets = if (byte == ']') @min(close_brackets + 1, 2) else 0;
                } else {
                    switch (probeUtf8(self.input[run_end..])) {
                        .incomplete => {
                            if (run_end != run_start) break;
                            return false;
                        },
                        .invalid => |relative_offset| {
                            if (run_end != run_start) break;
                            return self.failAt(
                                .malformed_utf8,
                                .invalid_xml,
                                locationWithByteDelta(config, start, relative_offset),
                            );
                        },
                        .scalar => |scalar| {
                            if (!self.isLiteralChar(scalar.codepoint)) {
                                if (run_end != run_start) break;
                                return self.failAt(.forbidden_character, .invalid_xml, start);
                            }
                            scalar_len = scalar.len;
                            close_brackets = 0;
                        },
                    }
                }

                const current_len = run_end - run_start;
                if (scalar_len > self.options.limits.max_fragment_bytes -| current_len) {
                    if (run_end == run_start) {
                        return self.fail(.fragment_limit, .limit_exceeded);
                    }
                    break;
                }
                run_end += scalar_len;
            }

            if (run_end == run_start) return false;
            const fragment = self.input[run_start..run_end];
            self.consumeRun(fragment);
            self.text_close_brackets = close_brackets;
            self.text_fragment = fragment;
            self.text_start = start;
            self.text_origin = .character_data;
            self.text_from_reference = false;
            self.text_resume = .content;
            self.vertical_state = .emit_text;
            return true;
        }

        fn contentHasOrdinaryPrefix(run: []const u8) bool {
            if (run.len < 64) return false;
            for (run[0..8]) |byte| {
                if (byte == '<' or byte == '&' or byte == '\r' or byte == ']') {
                    return false;
                }
            }
            return true;
        }

        noinline fn prepareBulkContentRun(
            self: *Self,
            candidate: []const u8,
            start: Location(config),
        ) bool {
            const unicode_dense = contentStartsUnicodeDense(candidate);
            if (comptime config.profile.isXml11()) {
                if (self.xmlVersion() == .xml11 and hasNonAscii(candidate)) return false;
            }
            const scan = if (unicode_dense) scanContentStructure(candidate) else null;
            var fast_len = if (scan) |result| result.delimiter_index else candidate.len;
            if (!unicode_dense) {
                inline for ("<&\r") |delimiter| {
                    if (std.mem.indexOfScalar(u8, candidate[0..fast_len], delimiter)) |index| {
                        fast_len = index;
                    }
                }
            }
            if (contentCdataCloseIndex(
                self.text_close_brackets,
                candidate[0..fast_len],
            )) |index| {
                fast_len = index;
            }
            const fast_run = candidate[0..fast_len];
            if (fast_run.len == 0 or
                !contentRunCanUseBulkPath(
                    fast_run,
                    if (scan) |result| result.has_non_ascii else hasNonAscii(fast_run),
                )) return false;
            self.consumeRun(fast_run);
            self.text_close_brackets = contentTrailingCloseBrackets(
                self.text_close_brackets,
                fast_run,
            );
            self.text_fragment = fast_run;
            self.text_start = start;
            self.text_origin = .character_data;
            self.text_from_reference = false;
            self.text_resume = .content;
            self.vertical_state = .emit_text;
            return true;
        }

        fn contentRunCanUseBulkPath(run: []const u8, has_non_ascii: bool) bool {
            if (has_non_ascii) {
                if (!utf8AndXmlControlsValid(run)) return false;
            } else if (hasForbiddenAsciiControl(run)) return false;
            return true;
        }

        fn contentCdataCloseIndex(close_brackets: u2, run: []const u8) ?usize {
            var earliest: ?usize = null;
            if (close_brackets == 2 and run.len > 0 and run[0] == '>') {
                earliest = 0;
            } else if (close_brackets == 1 and run.len > 1 and
                run[0] == ']' and run[1] == '>')
            {
                earliest = 1;
            }
            if (std.mem.indexOf(u8, run, "]]>")) |start| {
                const index = start + 2;
                if (earliest == null or index < earliest.?) earliest = index;
            }
            return earliest;
        }

        fn contentTrailingCloseBrackets(previous: u2, run: []const u8) u2 {
            std.debug.assert(run.len > 0);
            if (run[run.len - 1] != ']') return 0;
            if (run.len >= 2) return if (run[run.len - 2] == ']') 2 else 1;
            return @min(previous + 1, 2);
        }

        fn prepareInlineText(
            self: *Self,
            bytes: []const u8,
            start: Location(config),
        ) ReadError!void {
            if (bytes.len > self.options.limits.max_fragment_bytes) {
                return self.failAt(.fragment_limit, .limit_exceeded, start);
            }
            std.debug.assert(bytes.len <= self.text_inline.len);
            @memcpy(self.text_inline[0..bytes.len], bytes);
            self.text_fragment = self.text_inline[0..bytes.len];
            self.text_start = start;
            self.text_origin = .character_data;
            self.text_from_reference = false;
            self.text_resume = .content;
            self.vertical_state = .emit_text;
        }

        fn beginReference(self: *Self, context: ReferenceContext) ReadError!void {
            self.reference_context = context;
            self.reference_start = self.currentLocation();
            self.reference_value = 0;
            self.reference_has_digits = false;
            self.reference_token_bytes = 0;
            self.reference_name = @splat(0);
            self.reference_name_len = 0;
            if (comptime config.profile.dtdMode() == .validating) {
                if (context == .content) try self.noteValidationContentMarker(self.reference_start);
            }
            if (comptime config.profile.dtdMode() != .rejected) {
                self.dtd_state.reference_name.clearRetainingCapacity();
            }
            if (comptime config.profile.hasNamespaces()) {
                self.namespace_state.reference_colon = null;
            }
            try self.consumeReferenceByte('&');
            self.vertical_state = .reference_start;
        }

        fn prepareCompleteContentReference(self: *Self) ReadError!bool {
            const input = self.input[self.cursor..];
            const start = self.currentLocation();
            const predefined = .{
                .{ "&amp;", "&" },
                .{ "&lt;", "<" },
                .{ "&gt;", ">" },
                .{ "&apos;", "'" },
                .{ "&quot;", "\"" },
            };
            inline for (predefined) |entry| {
                const token = entry[0];
                const output = entry[1];
                if (std.mem.startsWith(u8, input, token) and
                    token.len <= self.options.limits.max_partial_token_bytes and
                    output.len <= self.options.limits.max_fragment_bytes)
                {
                    if (comptime config.profile.dtdMode() == .validating) {
                        try self.noteValidationContentMarker(start);
                    }
                    self.consumeRun(input[0..token.len]);
                    try self.prepareInlineText(output, start);
                    self.text_from_reference = true;
                    return true;
                }
            }

            if (!std.mem.startsWith(u8, input, "&#")) return false;
            var index: usize = 2;
            var kind: ReferenceKind = .decimal;
            if (index < input.len and input[index] == 'x') {
                kind = .hexadecimal;
                index += 1;
            }
            const digits_start = index;
            var value: u32 = 0;
            const base: u32 = if (kind == .hexadecimal) 16 else 10;
            while (index < input.len and input[index] != ';') : (index += 1) {
                const digit = referenceDigit(input[index], kind) orelse return false;
                if (value > (0x10ffff - digit) / base) return false;
                value = value * base + digit;
            }
            if (index == digits_start or index == input.len or
                index + 1 > self.options.limits.max_partial_token_bytes or
                !self.isReferenceChar(@intCast(value)))
            {
                return false;
            }
            var output: [4]u8 = undefined;
            const output_len = std.unicode.utf8Encode(@intCast(value), &output) catch
                unreachable;
            if (output_len > self.options.limits.max_fragment_bytes) return false;
            if (comptime config.profile.dtdMode() == .validating) {
                try self.noteValidationContentMarker(start);
            }
            self.consumeRun(input[0 .. index + 1]);
            try self.prepareInlineText(output[0..output_len], start);
            self.text_from_reference = true;
            return true;
        }

        fn consumeReferenceByte(self: *Self, byte: u8) ReadError!void {
            if (self.reference_token_bytes == self.options.limits.max_partial_token_bytes) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            if (self.reference_context == .attribute) {
                try self.requireStartTagByte();
                self.consumeStartTagByte(byte);
            } else {
                self.consumeByte(byte);
            }
            self.reference_token_bytes += 1;
        }

        fn readReferenceStart(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
                const start = self.utf8_start;
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                if (!isXml10NameStart(scalar.codepoint)) {
                    return self.failAt(.malformed_reference, .invalid_xml, start);
                }
                self.reference_name_len += scalar.len;
                try self.appendDtdReferenceName(self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                self.vertical_state = .reference_entity;
                return false;
            }
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == '#') {
                try self.consumeReferenceByte(byte);
                self.vertical_state = .reference_numeric_prefix;
                return false;
            }
            if (byte < 0x80) {
                if (!self.isLiteralChar(byte)) {
                    return self.failVoid(.forbidden_character, .invalid_xml);
                }
                if (!isXml10NameStart(byte)) {
                    return self.failVoid(.malformed_reference, .invalid_xml);
                }
                try self.consumeReferenceNameAscii(byte);
                self.vertical_state = .reference_entity;
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
            const start = self.utf8_start;
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            if (!isXml10NameStart(scalar.codepoint)) {
                return self.failAt(.malformed_reference, .invalid_xml, start);
            }
            self.reference_name_len += scalar.len;
            self.clearUtf8Scalar();
            self.vertical_state = .reference_entity;
            return false;
        }

        fn readReferenceNumericPrefix(self: *Self) ReadError!bool {
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == 'x') {
                self.reference_kind = .hexadecimal;
                try self.consumeReferenceByte(byte);
                self.vertical_state = .reference_numeric;
                return false;
            }
            self.reference_kind = .decimal;
            self.vertical_state = .reference_numeric;
            return false;
        }

        fn readReferenceNumeric(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                _ = (try self.readUtf8Scalar(.reference)) orelse return true;
                return self.failAt(
                    .malformed_reference,
                    .invalid_xml,
                    self.utf8_start,
                );
            }
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == ';') {
                if (!self.reference_has_digits) {
                    return self.failVoid(.malformed_reference, .invalid_xml);
                }
                try self.consumeReferenceByte(byte);
                try self.finishNumericReference();
                return false;
            }
            if (byte >= 0x80) {
                _ = (try self.readUtf8Scalar(.reference)) orelse return true;
                return self.failAt(
                    .malformed_reference,
                    .invalid_xml,
                    self.utf8_start,
                );
            }
            const digit = referenceDigit(byte, self.reference_kind) orelse {
                if (byte < 0x20 and !self.isLiteralChar(byte)) {
                    return self.failVoid(.forbidden_character, .invalid_xml);
                }
                return self.failVoid(.malformed_reference, .invalid_xml);
            };
            try self.consumeReferenceByte(byte);
            self.reference_has_digits = true;
            const base: u32 = if (self.reference_kind == .hexadecimal) 16 else 10;
            if (self.reference_value <= 0x10ffff and
                self.reference_value <= (0x10ffff - digit) / base)
            {
                self.reference_value = self.reference_value * base + digit;
            } else {
                self.reference_value = 0x110000;
            }
            return false;
        }

        fn readReferenceEntity(self: *Self) ReadError!bool {
            if (self.utf8_len != 0) {
                const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
                const start = self.utf8_start;
                if (!self.isLiteralChar(scalar.codepoint)) {
                    return self.failAt(.forbidden_character, .invalid_xml, start);
                }
                if (!isXml10NameChar(scalar.codepoint)) {
                    return self.failAt(.malformed_reference, .invalid_xml, start);
                }
                self.reference_name_len += scalar.len;
                try self.appendDtdReferenceName(self.utf8_bytes[0..scalar.len]);
                self.clearUtf8Scalar();
                return false;
            }
            if (self.cursor == self.input.len) return self.referenceNeedsInput();
            const byte = self.input[self.cursor];
            if (byte == ';') {
                try self.consumeReferenceByte(byte);
                try self.finishEntityReference();
                return false;
            }
            if (byte < 0x80) {
                if (!self.isLiteralChar(byte)) {
                    return self.failVoid(.forbidden_character, .invalid_xml);
                }
                if (!isXml10NameChar(byte)) {
                    return self.failVoid(.malformed_reference, .invalid_xml);
                }
                try self.consumeReferenceNameAscii(byte);
                return false;
            }
            const scalar = (try self.readUtf8Scalar(.reference)) orelse return true;
            const start = self.utf8_start;
            if (!self.isLiteralChar(scalar.codepoint)) {
                return self.failAt(.forbidden_character, .invalid_xml, start);
            }
            if (!isXml10NameChar(scalar.codepoint)) {
                return self.failAt(.malformed_reference, .invalid_xml, start);
            }
            self.reference_name_len += scalar.len;
            try self.appendDtdReferenceName(self.utf8_bytes[0..scalar.len]);
            self.clearUtf8Scalar();
            return false;
        }

        fn consumeReferenceNameAscii(self: *Self, byte: u8) ReadError!void {
            if (comptime config.profile.hasNamespaces()) {
                if (byte == ':' and self.namespace_state.reference_colon == null) {
                    self.namespace_state.reference_colon = self.currentLocation();
                }
            }
            try self.consumeReferenceByte(byte);
            if (self.reference_name_len < self.reference_name.len) {
                self.reference_name[self.reference_name_len] = byte;
            }
            try self.appendDtdReferenceName(&.{byte});
            self.reference_name_len += 1;
        }

        fn appendDtdReferenceName(self: *Self, bytes: []const u8) ReadError!void {
            if (comptime config.profile.dtdMode() == .rejected) return;
            self.dtd_state.reference_name.appendSlice(self.allocator, bytes) catch
                return self.failOutOfMemory();
        }

        fn referenceNeedsInput(self: *Self) ReadError!bool {
            if (self.final_input) {
                return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
            }
            return true;
        }

        fn finishNumericReference(self: *Self) ReadError!void {
            if (self.reference_value > 0x10ffff or
                !self.isReferenceChar(@intCast(self.reference_value)))
            {
                return self.failAt(
                    .invalid_character_reference,
                    .invalid_xml,
                    self.reference_start,
                );
            }
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(self.reference_value), &bytes) catch
                unreachable;
            try self.finishReferenceOutput(bytes[0..len]);
        }

        fn finishEntityReference(self: *Self) ReadError!void {
            const normalization_name = if (comptime config.profile.dtdMode() == .rejected)
                self.reference_name[0..@min(self.reference_name_len, self.reference_name.len)]
            else
                self.dtd_state.reference_name.items;
            try self.checkConstructNormalization(
                normalization_name,
                self.locationWithSemanticPrefix(self.reference_start, 1, ""),
                true,
            );
            if (comptime config.profile.hasNamespaces()) {
                if (self.namespace_state.reference_colon) |location| {
                    return self.failAt(.malformed_ncname, .invalid_xml, location);
                }
            }
            const short_name = self.reference_name[0..@min(self.reference_name_len, self.reference_name.len)];
            if (predefinedEntity(
                short_name,
                self.reference_name_len,
            )) |bytes| {
                try self.finishReferenceOutput(bytes);
                return;
            }
            if (comptime config.profile.dtdMode() == .rejected) {
                return self.failAt(.undeclared_entity, .invalid_xml, self.reference_start);
            }
            const name = self.dtd_state.reference_name.items;
            const entity_index = self.dtd_state.declarations.findGeneralEntity(
                self.options.dtd_limits,
                name,
            ) catch |err| return self.mapDtdError(err, .undeclared_entity);
            const index = entity_index orelse {
                if (self.reference_context == .content and
                    self.dtd_state.declarations.parameter_reference_seen and
                    !(self.standalone_declared and self.standalone))
                {
                    if (comptime config.profile.dtdMode() == .validating) {
                        try self.reportValidity(.{
                            .code = .undeclared_entity,
                            .occurrence = toValidationLocation(config, self.reference_start),
                        }, self.reference_start);
                    }
                    self.vertical_state = .emit_skipped_entity;
                    self.dtd_state.pending_skipped_entity_index = null;
                    return;
                }
                return self.failAt(.undeclared_entity, .invalid_xml, self.reference_start);
            };
            const entity = self.dtd_state.declarations.entities.items[index];
            if (entity.unparsed) return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
            if (self.standalone_declared and self.standalone and entity.declared_external) {
                return self.failAt(.undeclared_entity, .invalid_xml, self.reference_start);
            }
            if (entity.value == null) {
                if (self.reference_context == .attribute) {
                    return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
                }
                const system_id = entity.external_id.system_id orelse
                    return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
                if (comptime !config.external_sources) {
                    self.vertical_state = .emit_skipped_entity;
                    self.dtd_state.pending_skipped_entity_index = index;
                    return;
                }
                const external_source = (self.openExternalSource(
                    .general_entity,
                    name,
                    if (entity.external_id.public_id) |value|
                        self.dtd_state.declarations.string(value)
                    else
                        null,
                    self.dtd_state.declarations.string(system_id),
                    if (entity.base_id) |value| self.dtd_state.declarations.string(value) else null,
                    self.reference_start,
                ) catch |err| return self.mapDtdError(err, .malformed_reference)) orelse {
                    self.vertical_state = .emit_skipped_entity;
                    self.dtd_state.pending_skipped_entity_index = index;
                    return;
                };
                try self.pushExternalContentEntity(index, external_source);
                return;
            }
            if (self.reference_context == .attribute) {
                try self.expandAttributeEntity(index);
                self.vertical_state = .attribute_value;
            } else {
                try self.pushContentEntity(index);
            }
        }

        fn mapDtdError(
            self: *Self,
            err: dtd_module.ParseError,
            invalid_code: DiagnosticCode,
        ) ReadError {
            const code = self.dtdDiagnosticCode();
            const external_code: ?DiagnosticCode = if (comptime config.external_sources)
                self.dtd_state.external_failure_code
            else
                null;
            return switch (err) {
                error.InvalidDtd => self.failAt(
                    if (code == .malformed_dtd) invalid_code else code,
                    .invalid_dtd,
                    self.reference_start,
                ),
                error.UnsupportedFeature => self.failAt(code, .unsupported_feature, self.reference_start),
                error.LimitExceeded => self.failAt(external_code orelse code, .limit_exceeded, self.reference_start),
                error.OutOfMemory => self.failOutOfMemory(),
                error.ResolverFailed => self.failAt(external_code orelse .resolver_io_failure, .resolver_failed, self.reference_start),
                error.ReadFailed => self.failAt(external_code orelse .resolver_io_failure, .read_failed, self.reference_start),
                error.Cancelled => self.failAt(external_code orelse .resolver_cancelled, .cancelled, self.reference_start),
            };
        }

        fn chargeEntity(self: *Self, reference_bytes: usize, expanded_bytes: usize) ReadError!void {
            self.dtd_state.declarations.chargeEntity(
                self.options.dtd_limits,
                reference_bytes,
                expanded_bytes,
                @intCast(self.reference_start.byte_offset),
            ) catch |err| return self.mapDtdError(err, .malformed_reference);
        }

        fn chargeExternalExpansion(self: *Self, expanded_bytes: usize) ReadError!void {
            self.dtd_state.declarations.chargeExpanded(
                self.options.dtd_limits,
                expanded_bytes,
                @intCast(self.reference_start.byte_offset),
            ) catch |err| return self.mapDtdError(err, .malformed_reference);
        }

        fn pushContentEntity(self: *Self, entity_index: usize) ReadError!void {
            const value = self.dtd_state.declarations.string(
                self.dtd_state.declarations.entities.items[entity_index].value.?,
            );
            return self.pushContentEntityBytes(entity_index, value, self.dtd_state.source_id, false);
        }

        fn pushExternalContentEntity(
            self: *Self,
            entity_index: usize,
            source: resolver_module.Source,
        ) ReadError!void {
            for (self.dtd_state.entity_sources.items) |frame| {
                if (frame.entity_index == entity_index) {
                    source.close();
                    return self.failAt(.recursive_entity, .invalid_xml, self.reference_start);
                }
            }
            if (self.dtd_state.entity_sources.items.len ==
                self.options.dtd_limits.max_active_entity_depth)
            {
                source.close();
                return self.failAt(.entity_depth_limit, .limit_exceeded, self.reference_start);
            }
            self.chargeEntity(self.dtd_state.reference_name.items.len +| 2, 0) catch |err| {
                source.close();
                return err;
            };
            const parent_source_state = self.source_state;
            self.source_state = .{};
            self.dtd_state.entity_sources.append(self.allocator, .{
                .input = self.input,
                .cursor = self.cursor,
                .final_input = self.final_input,
                .source_byte_offset = self.source_byte_offset,
                .source_id = self.dtd_state.source_id,
                .position = self.position,
                .entity_index = entity_index,
                .open_depth = self.open_elements.items.len,
                .resume_state = .content,
                .parent_is_replacement = self.dtd_state.current_is_replacement,
                .external = true,
                .source_encoding = self.source_encoding,
                .source_state = parent_source_state,
                .active_external = self.dtd_state.active_external,
                .active_external_inclusion = self.dtd_state.active_external_inclusion,
            }) catch {
                self.source_state = parent_source_state;
                source.close();
                return self.failOutOfMemory();
            };
            self.dtd_state.active_external = source;
            self.dtd_state.active_external_inclusion = self.reference_start;
            self.source_state.external.transcoder = source.transcoder;
            if (source.transcoder != null or source.encoding_hint == .other) {
                self.source_state.encoding = .other;
                self.source_encoding = .other;
            }
            self.input = &.{};
            self.cursor = 0;
            self.final_input = false;
            self.source_byte_offset = 0;
            self.dtd_state.source_id = source.source_id;
            self.position = .{};
            self.dtd_state.pending_entity_index = entity_index;
            self.dtd_state.current_is_replacement = false;
            self.vertical_state = if (comptime config.report == .detailed)
                .emit_entity_start
            else
                .content;
        }

        fn pushContentEntityBytes(
            self: *Self,
            entity_index: usize,
            value: []const u8,
            entity_source_id: u32,
            external: bool,
        ) ReadError!void {
            for (self.dtd_state.entity_sources.items) |source| {
                if (source.entity_index == entity_index) {
                    return self.failAt(.recursive_entity, .invalid_xml, self.reference_start);
                }
            }
            if (self.dtd_state.entity_sources.items.len ==
                self.options.dtd_limits.max_active_entity_depth)
            {
                return self.failAt(.entity_depth_limit, .limit_exceeded, self.reference_start);
            }
            try self.chargeEntity(self.dtd_state.reference_name.items.len +| 2, value.len);
            self.dtd_state.entity_sources.append(self.allocator, .{
                .input = self.input,
                .cursor = self.cursor,
                .final_input = self.final_input,
                .source_byte_offset = self.source_byte_offset,
                .source_id = self.dtd_state.source_id,
                .position = self.position,
                .entity_index = entity_index,
                .open_depth = self.open_elements.items.len,
                .resume_state = .content,
                .parent_is_replacement = self.dtd_state.current_is_replacement,
            }) catch return self.failOutOfMemory();
            self.input = value;
            self.cursor = 0;
            self.final_input = false;
            if (external) {
                self.source_byte_offset = 0;
                self.dtd_state.source_id = entity_source_id;
                self.position = .{};
            }
            self.dtd_state.pending_entity_index = entity_index;
            self.dtd_state.current_is_replacement = true;
            self.vertical_state = if (comptime config.report == .detailed)
                .emit_entity_start
            else
                .content;
        }

        fn expandAttributeEntity(self: *Self, entity_index: usize) ReadError!void {
            const declarations = &self.dtd_state.declarations;
            self.dtd_state.attribute_sources.clearRetainingCapacity();
            const initial = declarations.string(declarations.entities.items[entity_index].value.?);
            try self.chargeEntity(self.dtd_state.reference_name.items.len +| 2, initial.len);
            self.dtd_state.attribute_sources.append(self.allocator, .{
                .bytes = initial,
                .entity_index = entity_index,
            }) catch return self.failOutOfMemory();
            while (self.dtd_state.attribute_sources.items.len != 0) {
                const top = &self.dtd_state.attribute_sources.items[
                    self.dtd_state.attribute_sources.items.len - 1
                ];
                if (top.cursor == top.bytes.len) {
                    _ = self.dtd_state.attribute_sources.pop();
                    continue;
                }
                const amp = std.mem.indexOfScalarPos(u8, top.bytes, top.cursor, '&') orelse {
                    const tail = top.bytes[top.cursor..];
                    if (std.mem.indexOfScalar(u8, tail, '<') != null) {
                        return self.failAt(.attribute_less_than, .invalid_xml, self.reference_start);
                    }
                    try self.appendAttributeOutput(tail);
                    top.cursor = top.bytes.len;
                    continue;
                };
                const prefix = top.bytes[top.cursor..amp];
                if (std.mem.indexOfScalar(u8, prefix, '<') != null) {
                    return self.failAt(.attribute_less_than, .invalid_xml, self.reference_start);
                }
                try self.appendAttributeOutput(prefix);
                const end = std.mem.indexOfScalarPos(u8, top.bytes, amp + 1, ';') orelse
                    return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
                const name = top.bytes[amp + 1 .. end];
                top.cursor = end + 1;
                if (predefinedEntity(name, name.len)) |bytes| {
                    try self.appendAttributeOutput(bytes);
                    continue;
                }
                const nested = (declarations.findGeneralEntity(self.options.dtd_limits, name) catch |err|
                    return self.mapDtdError(err, .malformed_reference)) orelse
                    return self.failAt(.undeclared_entity, .invalid_xml, self.reference_start);
                for (self.dtd_state.attribute_sources.items) |frame| {
                    if (frame.entity_index == nested) {
                        return self.failAt(.recursive_entity, .invalid_xml, self.reference_start);
                    }
                }
                if (self.dtd_state.attribute_sources.items.len ==
                    self.options.dtd_limits.max_active_entity_depth)
                {
                    return self.failAt(.entity_depth_limit, .limit_exceeded, self.reference_start);
                }
                const entity = declarations.entities.items[nested];
                if (entity.unparsed) return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
                if (entity.value == null) {
                    return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
                }
                const value = declarations.string(entity.value.?);
                try self.chargeEntity(name.len +| 2, value.len);
                self.dtd_state.attribute_sources.append(self.allocator, .{
                    .bytes = value,
                    .entity_index = nested,
                }) catch return self.failOutOfMemory();
            }
        }

        fn pendingEntityName(self: *const Self) []const u8 {
            const entity = self.dtd_state.declarations.entities.items[
                self.dtd_state.pending_entity_index
            ];
            return self.dtd_state.declarations.string(entity.name);
        }

        fn finishReferenceOutput(self: *Self, bytes: []const u8) ReadError!void {
            if (self.reference_context == .attribute) {
                try self.appendAttributeOutput(bytes);
                self.vertical_state = .attribute_value;
                return;
            }
            self.text_close_brackets = 0;
            try self.prepareInlineText(
                bytes,
                self.reference_start,
            );
            self.text_from_reference = true;
        }

        fn appendAttributeOutput(self: *Self, bytes: []const u8) ReadError!void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            const value_len = self.attribute_bytes.items.len - value_offset;
            const value_remaining = self.options.limits.max_attribute_value_bytes - value_len;
            if (bytes.len > value_remaining) {
                return self.failVoid(.attribute_value_limit, .limit_exceeded);
            }
            const aggregate_remaining = self.options.limits.max_attribute_bytes_per_element -
                self.attribute_bytes.items.len;
            if (bytes.len > aggregate_remaining) {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            self.attribute_bytes.appendSlice(self.allocator, bytes) catch
                return self.failOutOfMemory();
        }

        fn beginStartElement(self: *Self) ReadError!void {
            if (self.open_elements.items.len == self.options.limits.max_depth) {
                return self.failVoid(.depth_limit, .limit_exceeded);
            }
            std.debug.assert(self.attribute_records.items.len == 0);
            std.debug.assert(self.attribute_bytes.items.len == 0);
            std.debug.assert(self.event_attributes.items.len == 0);
            self.token_name_len = 0;
            self.vertical_state = .start_name;
        }

        fn appendStartNameRun(self: *Self, run: []const u8) ReadError!void {
            const partial_remaining = std.math.sub(
                usize,
                self.options.limits.max_partial_token_bytes,
                self.token_name_len,
            ) catch unreachable;
            const open_remaining = std.math.sub(
                usize,
                self.options.limits.max_open_name_bytes,
                self.open_names.items.len,
            ) catch unreachable;
            const start_tag_remaining = self.startTagRemaining();
            const qname_remaining = self.qnameRemaining(self.token_name_len);
            const accepted_len = @min(
                run.len,
                @min(
                    partial_remaining,
                    @min(open_remaining, @min(qname_remaining, start_tag_remaining)),
                ),
            );
            if (accepted_len > 0) {
                self.open_names.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeStartTagRun(run[0..accepted_len]);
                self.token_name_len += accepted_len;
            }
            if (accepted_len != run.len) {
                if (self.token_name_len == self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                if (self.open_names.items.len == self.options.limits.max_open_name_bytes) {
                    return self.failVoid(.open_name_limit, .limit_exceeded);
                }
                if (comptime config.profile.hasNamespaces()) {
                    if (self.token_name_len == self.options.namespace_limits.max_qname_bytes) {
                        return self.failVoid(.qname_limit, .limit_exceeded);
                    }
                }
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn ensureStartNameScalarCapacity(self: *Self) ReadError!void {
            const scalar_len = self.pendingUtf8ScalarLength() catch
                return self.failVoid(.malformed_utf8, .invalid_xml);
            if (scalar_len > self.options.limits.max_partial_token_bytes - self.token_name_len) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            if (scalar_len > self.options.limits.max_open_name_bytes - self.open_names.items.len) {
                return self.failVoid(.open_name_limit, .limit_exceeded);
            }
            if (scalar_len > self.qnameRemaining(self.token_name_len)) {
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
            if (scalar_len > self.startTagRemaining()) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn appendDecodedStartName(self: *Self, len: usize) ReadError!void {
            self.open_names.appendSlice(self.allocator, self.utf8_bytes[0..len]) catch
                return self.failOutOfMemory();
            self.token_name_len += len;
        }

        fn finishStartElement(self: *Self, empty_element: bool) ReadError!void {
            if (comptime config.profile.dtdMode() != .rejected) {
                try self.applyDtdAttributes();
            }
            try self.checkStartElementNormalization();
            if (comptime config.profile.hasNamespaces()) {
                const binding_mark = self.namespace_state.bindings.items.len;
                const byte_mark = self.namespace_state.bytes.items.len;
                const namespace_reference = try self.prepareNamespaceStartElement();
                const validation_frame = if (comptime config.profile.dtdMode() == .validating)
                    try self.beginValidationElement(empty_element)
                else {};
                self.open_elements.append(self.allocator, .{
                    .name_offset = self.open_names.items.len - self.token_name_len,
                    .name_len = self.token_name_len,
                    .start = self.token_start,
                    .namespace_binding_mark = binding_mark,
                    .namespace_byte_mark = byte_mark,
                    .namespace_reference = namespace_reference,
                    .validation = validation_frame,
                }) catch return self.failOutOfMemory();
            } else {
                try self.prepareEventAttributes();
                const validation_frame = if (comptime config.profile.dtdMode() == .validating)
                    try self.beginValidationElement(empty_element)
                else {};
                self.open_elements.append(self.allocator, .{
                    .name_offset = self.open_names.items.len - self.token_name_len,
                    .name_len = self.token_name_len,
                    .start = self.token_start,
                    .validation = validation_frame,
                }) catch return self.failOutOfMemory();
            }
            self.vertical_state = if (empty_element)
                .emit_empty_start_element
            else
                .emit_start_element;
            self.resetConstructNormalization();
        }

        fn checkStartElementNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) return;
            if (self.normalization_status == .unchecked) return;
            const element_name = self.open_names.items[self.open_names.items.len - self.token_name_len ..];
            try self.checkConstructNormalization(
                element_name,
                self.locationWithSemanticPrefix(self.token_start, 1, ""),
                true,
            );
            for (self.attribute_records.items) |record| {
                try self.checkConstructNormalization(
                    self.attributeRawName(record),
                    record.start,
                    true,
                );
                const value_offset = record.name_offset + record.name_len;
                const value = self.attribute_bytes.items[value_offset..][0..record.value_len];
                try self.checkConstructNormalization(value, record.start, false);
                if (comptime config.profile.dtdMode() != .rejected) {
                    if (record.declared_type != null and record.declared_type.? != .cdata) {
                        try self.checkNormalizationTokens(value, record.start);
                    }
                }
            }
        }

        fn beginValidationElement(self: *Self, empty_element: bool) ReadError!validation_module.Frame {
            const declarations = &self.dtd_state.declarations;
            const name = self.open_names.items[self.open_names.items.len - self.token_name_len ..];
            const location = toValidationLocation(config, self.token_start);
            if (self.open_elements.items.len != 0) {
                const parent = &self.open_elements.items[self.open_elements.items.len - 1].validation;
                if (self.validation_state.advance(
                    self.options.validation.limits,
                    declarations,
                    parent,
                    name,
                    location,
                ) catch |err| return self.mapValidationError(err)) |issue| {
                    try self.reportValidity(issue, self.token_start);
                }
            }
            var beginning = self.validation_state.beginElement(
                self.options.validation.limits,
                declarations,
                name,
                location,
            ) catch |err| return self.mapValidationError(err);
            if (beginning.issue) |issue| try self.reportValidity(issue, self.token_start);
            try self.validateStartAttributes(name);
            if (empty_element) {
                if (self.validation_state.finishElement(&beginning.frame, location)) |issue| {
                    try self.reportValidity(issue, self.token_start);
                }
            }
            return beginning.frame;
        }

        fn validateStartAttributes(self: *Self, element_name: []const u8) ReadError!void {
            const declarations = &self.dtd_state.declarations;
            for (self.attribute_records.items) |record| {
                const declaration_index = record.declaration_index orelse {
                    try self.reportValidity(.{
                        .code = .undeclared_attribute,
                        .occurrence = toValidationLocation(config, record.start),
                    }, record.start);
                    continue;
                };
                const declaration = declarations.attributes.items[declaration_index];
                const value_offset = record.name_offset + record.name_len;
                const value = self.attribute_bytes.items[value_offset..][0..record.value_len];
                if (declaration.default_kind == .fixed and record.specified and
                    !std.mem.eql(u8, value, declarations.string(declaration.default_value.?)))
                {
                    try self.reportValidity(.{
                        .code = .fixed_attribute_mismatch,
                        .related = declaration.location,
                        .occurrence = toValidationLocation(config, record.start),
                    }, record.start);
                }
                if (self.standalone_declared and self.standalone and declaration.declared_external) {
                    if (!record.specified) {
                        try self.reportValidity(.{
                            .code = .standalone_external_default,
                            .related = declaration.location,
                            .occurrence = toValidationLocation(config, record.start),
                        }, record.start);
                    } else if (record.normalization_changed) {
                        try self.reportValidity(.{
                            .code = .standalone_external_normalization,
                            .related = declaration.location,
                            .occurrence = toValidationLocation(config, record.start),
                        }, record.start);
                    }
                }
                try self.validateAttributeValue(declaration, value, record.start);
            }
            for (declarations.attributes.items) |declaration| {
                if (declaration.default_kind != .required or
                    !std.mem.eql(u8, declarations.string(declaration.element_name), element_name))
                {
                    continue;
                }
                var present = false;
                for (self.attribute_records.items) |record| {
                    if (record.declaration_index != null and
                        record.declaration_index.? == declaration.order)
                    {
                        present = true;
                        break;
                    }
                }
                if (!present) try self.reportValidity(.{
                    .code = .required_attribute_missing,
                    .related = declaration.location,
                    .occurrence = toValidationLocation(config, self.token_start),
                }, self.token_start);
            }
        }

        fn validateAttributeValue(
            self: *Self,
            declaration: dtd_module.AttributeDeclaration,
            value: []const u8,
            location: Location(config),
        ) ReadError!void {
            const source = toValidationLocation(config, location);
            var valid = true;
            switch (declaration.attribute_type) {
                .cdata => {},
                .id => {
                    valid = validValidationName(config, value);
                    if (valid) {
                        if (self.validation_state.addId(
                            self.allocator,
                            self.options.validation.limits,
                            value,
                            source,
                        ) catch |err| return self.mapValidationError(err)) |issue| {
                            try self.reportValidity(issue, location);
                        }
                    }
                },
                .idref, .idrefs => {
                    var tokens = SpaceTokenIterator.init(value);
                    var count: usize = 0;
                    while (tokens.next()) |token| {
                        count += 1;
                        if (!validValidationName(config, token)) {
                            valid = false;
                            continue;
                        }
                        self.validation_state.addIdref(
                            self.allocator,
                            self.options.validation.limits,
                            token,
                            source,
                        ) catch |err| return self.mapValidationError(err);
                    }
                    valid = valid and count != 0 and
                        (declaration.attribute_type == .idrefs or count == 1);
                },
                .entity, .entities => {
                    var tokens = SpaceTokenIterator.init(value);
                    var count: usize = 0;
                    while (tokens.next()) |token| {
                        count += 1;
                        if (!validValidationName(config, token) or !(try self.isUnparsedEntity(token))) {
                            valid = false;
                        }
                    }
                    valid = valid and count != 0 and
                        (declaration.attribute_type == .entities or count == 1);
                },
                .nmtoken, .nmtokens => {
                    var tokens = SpaceTokenIterator.init(value);
                    var count: usize = 0;
                    while (tokens.next()) |token| {
                        count += 1;
                        if (!dtd_module.validNmtoken(token)) valid = false;
                    }
                    valid = valid and count != 0 and
                        (declaration.attribute_type == .nmtokens or count == 1);
                },
                .enumeration, .notation => {
                    valid = dtd_module.validNmtoken(value) and
                        validation_module.groupContains(
                            self.dtd_state.declarations.string(declaration.allowed_values.?),
                            value,
                        );
                },
            }
            if (!valid) try self.reportValidity(.{
                .code = .invalid_attribute_value,
                .related = declaration.location,
                .occurrence = source,
            }, location);
        }

        fn isUnparsedEntity(self: *Self, name: []const u8) ReadError!bool {
            const index = self.dtd_state.declarations.findGeneralEntity(
                self.options.dtd_limits,
                name,
            ) catch |err| return self.mapDtdError(err, .malformed_attribute);
            return if (index) |value| self.dtd_state.declarations.entities.items[value].unparsed else false;
        }

        fn beginAttribute(self: *Self) ReadError!void {
            if (self.attribute_records.items.len ==
                self.options.limits.max_attributes_per_element)
            {
                return self.failVoid(.attribute_count_limit, .limit_exceeded);
            }
            if (self.attribute_bytes.items.len ==
                self.options.limits.max_attribute_bytes_per_element)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            try self.requireStartTagByte();
            self.attribute_records.append(self.allocator, .{
                .name_offset = self.attribute_bytes.items.len,
                .name_len = 0,
                .value_len = 0,
                .start = self.currentLocation(),
            }) catch return self.failOutOfMemory();
            self.vertical_state = .attribute_name;
        }

        fn appendAttributeNameRun(self: *Self, run: []const u8) ReadError!void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const name_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_name_bytes,
                record.name_len,
            ) catch unreachable;
            const aggregate_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_bytes_per_element,
                self.attribute_bytes.items.len,
            ) catch unreachable;
            const qname_remaining = self.qnameRemaining(record.name_len);
            const accepted_len = @min(
                run.len,
                @min(
                    name_remaining,
                    @min(aggregate_remaining, @min(qname_remaining, self.startTagRemaining())),
                ),
            );
            if (accepted_len > 0) {
                self.attribute_bytes.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeStartTagRun(run[0..accepted_len]);
                record.name_len += accepted_len;
            }
            if (accepted_len != run.len) {
                if (record.name_len == self.options.limits.max_attribute_name_bytes) {
                    return self.failVoid(.attribute_name_limit, .limit_exceeded);
                }
                if (self.attribute_bytes.items.len ==
                    self.options.limits.max_attribute_bytes_per_element)
                {
                    return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
                }
                if (comptime config.profile.hasNamespaces()) {
                    if (record.name_len == self.options.namespace_limits.max_qname_bytes) {
                        return self.failVoid(.qname_limit, .limit_exceeded);
                    }
                }
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn ensureAttributeNameScalarCapacity(self: *Self) ReadError!void {
            const scalar_len = self.pendingUtf8ScalarLength() catch
                return self.failVoid(.malformed_utf8, .invalid_xml);
            const record = self.attribute_records.items[self.attribute_records.items.len - 1];
            if (scalar_len > self.options.limits.max_attribute_name_bytes - record.name_len) {
                return self.failVoid(.attribute_name_limit, .limit_exceeded);
            }
            if (scalar_len > self.options.limits.max_attribute_bytes_per_element -
                self.attribute_bytes.items.len)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            if (scalar_len > self.qnameRemaining(record.name_len)) {
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
            if (scalar_len > self.startTagRemaining()) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn appendDecodedAttributeName(self: *Self, len: usize) ReadError!void {
            self.attribute_bytes.appendSlice(
                self.allocator,
                self.utf8_bytes[0..len],
            ) catch return self.failOutOfMemory();
            self.attribute_records.items[self.attribute_records.items.len - 1].name_len += len;
        }

        fn qnameRemaining(self: *const Self, current_len: usize) usize {
            if (comptime !config.profile.hasNamespaces()) return std.math.maxInt(usize);
            return self.options.namespace_limits.max_qname_bytes - current_len;
        }

        fn appendAttributeValueRun(self: *Self, run: []const u8) ReadError!void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            const value_len = self.attribute_bytes.items.len - value_offset;
            const value_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_value_bytes,
                value_len,
            ) catch unreachable;
            const aggregate_remaining = std.math.sub(
                usize,
                self.options.limits.max_attribute_bytes_per_element,
                self.attribute_bytes.items.len,
            ) catch unreachable;
            const accepted_len = @min(
                run.len,
                @min(value_remaining, @min(aggregate_remaining, self.startTagRemaining())),
            );
            if (accepted_len > 0) {
                self.attribute_bytes.appendSlice(
                    self.allocator,
                    run[0..accepted_len],
                ) catch return self.failOutOfMemory();
                self.consumeStartTagRun(run[0..accepted_len]);
            }
            if (accepted_len != run.len) {
                if (value_len + accepted_len ==
                    self.options.limits.max_attribute_value_bytes)
                {
                    return self.failVoid(.attribute_value_limit, .limit_exceeded);
                }
                if (self.attribute_bytes.items.len ==
                    self.options.limits.max_attribute_bytes_per_element)
                {
                    return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
                }
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn ensureAttributeValueScalarCapacity(self: *Self) ReadError!void {
            const scalar_len = self.pendingUtf8ScalarLength() catch
                return self.failVoid(.malformed_utf8, .invalid_xml);
            const record = self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            const value_len = self.attribute_bytes.items.len - value_offset;
            if (scalar_len > self.options.limits.max_attribute_value_bytes - value_len) {
                return self.failVoid(.attribute_value_limit, .limit_exceeded);
            }
            if (scalar_len > self.options.limits.max_attribute_bytes_per_element -
                self.attribute_bytes.items.len)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            if (scalar_len > self.startTagRemaining()) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn finishAttribute(self: *Self) void {
            const record = &self.attribute_records.items[self.attribute_records.items.len - 1];
            const value_offset = record.name_offset + record.name_len;
            record.value_len = self.attribute_bytes.items.len - value_offset;
        }

        fn prepareNamespaceStartElement(self: *Self) ReadError!NamespaceReference {
            try self.rejectDuplicateAttributes();
            self.namespace_state.event_declarations.clearRetainingCapacity();
            self.namespace_state.expanded_indices.clearRetainingCapacity();
            self.namespace_state.event_attribute_locations.clearRetainingCapacity();
            self.namespace_state.comparison_work = 0;

            const element_raw = self.open_names.items[self.open_names.items.len - self.token_name_len ..];
            const element_name_start = self.locationWithSemanticPrefix(
                self.token_start,
                1,
                "",
            );
            const element_parts = try self.requireQName(element_raw, element_name_start);
            if (element_parts.prefix) |prefix| {
                if (std.mem.eql(u8, prefix, "xmlns")) {
                    return self.failAt(
                        .reserved_namespace_name,
                        .invalid_xml,
                        element_name_start,
                    );
                }
            }

            var declaration_count: usize = 0;
            for (self.attribute_records.items) |*record| {
                const raw = self.attributeRawName(record.*);
                const parts = try self.requireQName(raw, record.start);
                if (namespaceDeclarationPrefix(raw, parts)) |declared_prefix| {
                    record.namespace_shape = std.math.maxInt(usize);
                    declaration_count += 1;
                    if (declaration_count >
                        self.options.namespace_limits.max_declarations_per_element)
                    {
                        return self.failAt(
                            .namespace_declaration_limit,
                            .limit_exceeded,
                            record.start,
                        );
                    }
                    try self.addNamespaceDeclaration(record.*, declared_prefix);
                } else if (parts.prefix) |prefix| {
                    record.namespace_shape = prefix.len + 1;
                }
            }

            const element_reference = try self.resolveNamespace(
                element_parts.prefix orelse "",
                element_name_start,
            );

            const ordinary_count = self.attribute_records.items.len - declaration_count;
            self.event_attributes.clearRetainingCapacity();
            self.event_attributes.ensureTotalCapacity(
                self.allocator,
                ordinary_count,
            ) catch return self.failOutOfMemory();
            self.namespace_state.expanded_indices.ensureTotalCapacity(
                self.allocator,
                ordinary_count,
            ) catch return self.failOutOfMemory();
            self.namespace_state.event_attribute_locations.ensureTotalCapacity(
                self.allocator,
                ordinary_count,
            ) catch return self.failOutOfMemory();

            for (self.attribute_records.items) |record| {
                const raw = self.attributeRawName(record);
                if (record.namespace_shape == std.math.maxInt(usize)) continue;
                const parts: QNameParts = if (record.namespace_shape == 0)
                    .{ .prefix = null, .local = raw }
                else parts: {
                    const colon = record.namespace_shape - 1;
                    break :parts .{
                        .prefix = raw[0..colon],
                        .local = raw[colon + 1 ..],
                    };
                };
                if (parts.prefix) |prefix| {
                    if (std.mem.eql(u8, prefix, "xmlns")) {
                        return self.failAt(
                            .reserved_namespace_name,
                            .invalid_xml,
                            record.start,
                        );
                    }
                }
                const reference = if (parts.prefix) |prefix|
                    try self.resolveNamespace(prefix, record.start)
                else
                    NamespaceReference.none;
                const value_offset = record.name_offset + record.name_len;
                if (comptime config.profile.dtdMode() == .rejected) {
                    self.event_attributes.appendAssumeCapacity(.{
                        .name = self.expandedName(raw, parts, reference),
                        .value = self.attribute_bytes.items[value_offset..][0..record.value_len],
                    });
                } else {
                    self.event_attributes.appendAssumeCapacity(.{
                        .name = self.expandedName(raw, parts, reference),
                        .value = self.attribute_bytes.items[value_offset..][0..record.value_len],
                        .specified = record.specified,
                        .declared_type = record.declared_type,
                    });
                }
                self.namespace_state.expanded_indices.appendAssumeCapacity(
                    self.event_attributes.items.len - 1,
                );
                self.namespace_state.event_attribute_locations.appendAssumeCapacity(record.start);
            }
            try self.rejectDuplicateExpandedAttributes();
            return element_reference;
        }

        fn requireQName(
            self: *Self,
            raw: []const u8,
            start: Location(config),
        ) ReadError!QNameParts {
            if (raw.len > self.options.namespace_limits.max_qname_bytes) {
                return self.failAt(
                    .qname_limit,
                    .limit_exceeded,
                    self.locationWithSemanticPrefix(
                        start,
                        0,
                        raw[0..self.options.namespace_limits.max_qname_bytes],
                    ),
                );
            }
            return qnameParts(raw) orelse self.failAt(
                .malformed_qname,
                .invalid_xml,
                self.locationWithSemanticPrefix(start, 0, raw[0..qnameErrorIndex(raw)]),
            );
        }

        fn locationWithSemanticPrefix(
            self: *const Self,
            location: Location(config),
            ascii_prefix_len: usize,
            utf8_prefix: []const u8,
        ) Location(config) {
            const delta: u64 = if (self.source_encoding == .utf8)
                ascii_prefix_len + utf8_prefix.len
            else
                2 * @as(u64, @intCast(ascii_prefix_len)) + utf16SourceBytes(utf8_prefix);
            var result = location;
            result.byte_offset += delta;
            if (config.diagnostic_location == .line_column) result.byte_column += delta;
            return result;
        }

        fn addNamespaceDeclaration(
            self: *Self,
            record: AttributeRecord(config),
            declared_prefix: []const u8,
        ) ReadError!void {
            const raw = self.attributeRawName(record);
            const uri_offset = record.name_offset + record.name_len;
            const uri = self.attribute_bytes.items[uri_offset..][0..record.value_len];
            const is_default = std.mem.eql(u8, raw, "xmlns");

            if ((!is_default and uri.len == 0 and self.xmlVersion() == .xml10) or
                std.mem.eql(u8, declared_prefix, "xmlns") or
                std.mem.eql(u8, uri, xmlns_namespace_uri) or
                (std.mem.eql(u8, declared_prefix, "xml") !=
                    std.mem.eql(u8, uri, xml_namespace_uri)))
            {
                return self.failAt(
                    .illegal_namespace_declaration,
                    .invalid_xml,
                    record.start,
                );
            }
            if (std.mem.eql(u8, declared_prefix, "xml")) {
                self.namespace_state.event_declarations.append(self.allocator, .{
                    .prefix = declared_prefix,
                    .namespace_uri = uri,
                }) catch return self.failOutOfMemory();
                return;
            }
            if (self.namespace_state.bindings.items.len ==
                self.options.namespace_limits.max_active_bindings)
            {
                return self.failAt(.namespace_binding_limit, .limit_exceeded, record.start);
            }
            const added_bytes = std.math.add(usize, declared_prefix.len, uri.len) catch
                return self.failAt(.namespace_binding_bytes_limit, .limit_exceeded, record.start);
            if (added_bytes > self.options.namespace_limits.max_binding_bytes -
                self.namespace_state.bytes.items.len)
            {
                return self.failAt(
                    .namespace_binding_bytes_limit,
                    .limit_exceeded,
                    record.start,
                );
            }

            const prefix_offset = self.namespace_state.bytes.items.len;
            self.namespace_state.bytes.appendSlice(self.allocator, declared_prefix) catch
                return self.failOutOfMemory();
            const stored_uri_offset = self.namespace_state.bytes.items.len;
            self.namespace_state.bytes.appendSlice(self.allocator, uri) catch
                return self.failOutOfMemory();
            const active = try self.findActivePrefix(declared_prefix, record.start);
            const binding_index = self.namespace_state.bindings.items.len;
            self.namespace_state.bindings.append(self.allocator, .{
                .prefix_offset = prefix_offset,
                .prefix_len = declared_prefix.len,
                .uri_offset = stored_uri_offset,
                .uri_len = uri.len,
                .previous_binding = if (active.found)
                    self.namespace_state.active_prefixes.items[active.index]
                else
                    null,
                .active_index = active.index,
            }) catch return self.failOutOfMemory();
            if (active.found) {
                self.namespace_state.active_prefixes.items[active.index] = binding_index;
            } else {
                self.namespace_state.active_prefixes.insert(
                    self.allocator,
                    active.index,
                    binding_index,
                ) catch return self.failOutOfMemory();
            }
            self.namespace_state.event_declarations.append(self.allocator, .{
                .prefix = if (is_default) null else raw["xmlns:".len..],
                .namespace_uri = uri,
            }) catch return self.failOutOfMemory();
        }

        fn resolveNamespace(
            self: *Self,
            prefix: []const u8,
            location: Location(config),
        ) ReadError!NamespaceReference {
            if (std.mem.eql(u8, prefix, "xml")) return .predefined_xml;
            const active = try self.findActivePrefix(prefix, location);
            if (active.found) {
                const binding_index = self.namespace_state.active_prefixes.items[active.index];
                const binding = self.namespace_state.bindings.items[binding_index];
                if (binding.uri_len != 0) return .{ .binding = binding_index };
                if (prefix.len == 0) return .none;
                return self.failAt(.unbound_prefix, .invalid_xml, location);
            }
            if (prefix.len == 0) return .none;
            return self.failAt(.unbound_prefix, .invalid_xml, location);
        }

        const ActivePrefixSearch = struct {
            index: usize,
            found: bool,
        };

        fn findActivePrefix(
            self: *Self,
            prefix: []const u8,
            location: Location(config),
        ) ReadError!ActivePrefixSearch {
            var low: usize = 0;
            var high = self.namespace_state.active_prefixes.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const binding_index = self.namespace_state.active_prefixes.items[middle];
                const binding = self.namespace_state.bindings.items[binding_index];
                const stored_prefix = self.namespace_state.bytes.items[binding.prefix_offset..][0..binding.prefix_len];
                try self.chargeNamespaceComparison(
                    prefix.len +| stored_prefix.len +| 1,
                    location,
                );
                switch (std.mem.order(u8, stored_prefix, prefix)) {
                    .lt => low = middle + 1,
                    .gt => high = middle,
                    .eq => return .{ .index = middle, .found = true },
                }
            }
            return .{ .index = low, .found = false };
        }

        fn expandedName(
            self: *const Self,
            raw: []const u8,
            parts: QNameParts,
            reference: NamespaceReference,
        ) ExpandedName {
            return .{
                .raw = raw,
                .prefix = parts.prefix,
                .local = parts.local,
                .namespace_uri = self.namespaceUri(reference),
            };
        }

        fn namespaceUri(self: *const Self, reference: NamespaceReference) ?[]const u8 {
            return switch (reference) {
                .none => null,
                .predefined_xml => xml_namespace_uri,
                .binding => |index| uri: {
                    const binding = self.namespace_state.bindings.items[index];
                    break :uri self.namespace_state.bytes.items[binding.uri_offset..][0..binding.uri_len];
                },
            };
        }

        fn chargeNamespaceComparison(
            self: *Self,
            amount: usize,
            location: Location(config),
        ) ReadError!void {
            if (!self.namespaceComparisonAllowed(amount)) {
                return self.failAt(.namespace_comparison_limit, .limit_exceeded, location);
            }
        }

        fn namespaceComparisonAllowed(self: *Self, amount: usize) bool {
            const remaining = self.options.namespace_limits.max_comparison_work -|
                self.namespace_state.comparison_work;
            if (amount > remaining) {
                return false;
            }
            self.namespace_state.comparison_work += amount;
            return true;
        }

        fn rejectDuplicateExpandedAttributes(self: *Self) ReadError!void {
            const attributes = self.event_attributes.items;
            if (attributes.len <= linear_duplicate_threshold) {
                for (attributes, 0..) |attribute, index| {
                    for (attributes[0..index], 0..) |previous, previous_index| {
                        try self.chargeNamespaceComparison(
                            expandedComparisonCost(attribute.name, previous.name),
                            self.currentLocation(),
                        );
                        if (expandedNamesEqual(attribute.name, previous.name)) {
                            return self.failRelated(
                                .duplicate_expanded_attribute,
                                .invalid_xml,
                                self.namespace_state.event_attribute_locations.items[index],
                                self.namespace_state.event_attribute_locations.items[previous_index],
                            );
                        }
                    }
                }
                return;
            }

            try self.ensureExpandedSortWork(attributes);
            std.sort.heap(
                usize,
                self.namespace_state.expanded_indices.items,
                self,
                expandedAttributeIndexLessThan,
            );
            const indices = self.namespace_state.expanded_indices.items;
            for (indices[1..], indices[0 .. indices.len - 1]) |index, previous_index| {
                const attribute = attributes[index];
                const previous = attributes[previous_index];
                try self.chargeNamespaceComparison(
                    expandedComparisonCost(attribute.name, previous.name),
                    self.currentLocation(),
                );
                if (expandedNamesEqual(attribute.name, previous.name)) {
                    return self.failRelated(
                        .duplicate_expanded_attribute,
                        .invalid_xml,
                        self.namespace_state.event_attribute_locations.items[index],
                        self.namespace_state.event_attribute_locations.items[previous_index],
                    );
                }
            }
        }

        fn expandedAttributeIndexLessThan(
            self: *Self,
            left_index: usize,
            right_index: usize,
        ) bool {
            const left = self.event_attributes.items[left_index].name;
            const right = self.event_attributes.items[right_index].name;
            const uri_order = optionalBytesOrder(left.namespace_uri, right.namespace_uri);
            if (uri_order != .eq) return uri_order == .lt;
            const local_order = std.mem.order(u8, left.local, right.local);
            if (local_order != .eq) return local_order == .lt;
            return left_index < right_index;
        }

        fn ensureExpandedSortWork(
            self: *Self,
            attributes: []const Attribute(config),
        ) ReadError!void {
            var max_uri_len: usize = 0;
            var max_local_len: usize = 0;
            for (attributes) |attribute| {
                max_uri_len = @max(
                    max_uri_len,
                    optionalBytesLength(attribute.name.namespace_uri),
                );
                max_local_len = @max(max_local_len, attribute.name.local.len);
            }
            var levels: usize = 1;
            var width = attributes.len;
            while (width > 1) : (levels +|= 1) width = (width + 1) / 2;
            // The factor bounds heap-sort comparisons; the final term covers adjacency checks.
            const comparison_bound = 8 *| attributes.len *| levels +| attributes.len;
            const cost_bound = 2 *| max_uri_len +| 2 *| max_local_len +| 2;
            const work_bound = comparison_bound *| cost_bound;
            const remaining = self.options.namespace_limits.max_comparison_work -|
                self.namespace_state.comparison_work;
            if (work_bound > remaining) {
                return self.fail(.namespace_comparison_limit, .limit_exceeded);
            }
        }

        fn prepareEventAttributes(self: *Self) ReadError!void {
            try self.rejectDuplicateAttributes();
            self.event_attributes.clearRetainingCapacity();
            self.event_attributes.ensureTotalCapacity(
                self.allocator,
                self.attribute_records.items.len,
            ) catch return self.failOutOfMemory();
            for (self.attribute_records.items) |record| {
                const raw_name = self.attributeRawName(record);
                const value_offset = record.name_offset + record.name_len;
                if (comptime config.profile.dtdMode() == .rejected) {
                    self.event_attributes.appendAssumeCapacity(.{
                        .name = nameFromRaw(config, raw_name),
                        .value = self.attribute_bytes.items[value_offset..][0..record.value_len],
                    });
                } else {
                    self.event_attributes.appendAssumeCapacity(.{
                        .name = nameFromRaw(config, raw_name),
                        .value = self.attribute_bytes.items[value_offset..][0..record.value_len],
                        .specified = record.specified,
                        .declared_type = record.declared_type,
                    });
                }
            }
        }

        fn applyDtdAttributes(self: *Self) ReadError!void {
            const declarations = &self.dtd_state.declarations;
            if (declarations.root_name == null) return;
            const element_name = self.open_names.items[self.open_names.items.len - self.token_name_len ..];

            var source_index: usize = 0;
            while (source_index < self.attribute_records.items.len) : (source_index += 1) {
                const record = &self.attribute_records.items[source_index];
                const declaration_index = declarations.findAttribute(
                    self.options.dtd_limits,
                    element_name,
                    self.attributeRawName(record.*),
                ) catch |err| return self.mapDtdError(err, .malformed_attribute);
                if (declaration_index) |index| {
                    record.declaration_index = index;
                    record.declared_type = declarations.attributes.items[index].attribute_type;
                    if (record.declared_type.?.isTokenized()) {
                        self.collapseAttributeValue(source_index);
                    }
                }
            }

            for (declarations.attributes.items, 0..) |declaration, declaration_index| {
                const applies = declarations.equalStored(
                    self.options.dtd_limits,
                    declaration.element_name,
                    element_name,
                ) catch |err| return self.mapDtdError(err, .malformed_attribute);
                if (!applies or declaration.default_value == null) continue;
                const name = declarations.string(declaration.name);
                var present = false;
                for (self.attribute_records.items) |record| {
                    const matches = declarations.equalStored(
                        self.options.dtd_limits,
                        declaration.name,
                        self.attributeRawName(record),
                    ) catch |err| return self.mapDtdError(err, .malformed_attribute);
                    if (matches) {
                        present = true;
                        break;
                    }
                }
                if (present) continue;
                try self.appendDefaultAttribute(
                    name,
                    declarations.string(declaration.default_value.?),
                    declaration_index,
                );
            }
        }

        fn collapseAttributeValue(self: *Self, record_index: usize) void {
            const record = &self.attribute_records.items[record_index];
            const value_offset = record.name_offset + record.name_len;
            const old_len = record.value_len;
            const new_len = dtd_module.collapseSpaces(
                self.attribute_bytes.items[value_offset..][0..old_len],
            );
            if (new_len == old_len) return;
            record.normalization_changed = true;
            const removed = old_len - new_len;
            std.mem.copyForwards(
                u8,
                self.attribute_bytes.items[value_offset + new_len .. self.attribute_bytes.items.len - removed],
                self.attribute_bytes.items[value_offset + old_len ..],
            );
            self.attribute_bytes.items.len -= removed;
            record.value_len = new_len;
            for (self.attribute_records.items[record_index + 1 ..]) |*later| {
                later.name_offset -= removed;
            }
        }

        fn appendDefaultAttribute(
            self: *Self,
            name: []const u8,
            value: []const u8,
            declaration_index: usize,
        ) ReadError!void {
            if (self.attribute_records.items.len == self.options.limits.max_attributes_per_element) {
                return self.failVoid(.attribute_count_limit, .limit_exceeded);
            }
            if (name.len > self.options.limits.max_attribute_name_bytes) {
                return self.failVoid(.attribute_name_limit, .limit_exceeded);
            }
            if (value.len > self.options.limits.max_attribute_value_bytes) {
                return self.failVoid(.attribute_value_limit, .limit_exceeded);
            }
            if (comptime config.profile.hasNamespaces()) {
                if (name.len > self.options.namespace_limits.max_qname_bytes) {
                    return self.failVoid(.qname_limit, .limit_exceeded);
                }
            }
            if (name.len +| value.len > self.options.limits.max_attribute_bytes_per_element -|
                self.attribute_bytes.items.len)
            {
                return self.failVoid(.attribute_bytes_limit, .limit_exceeded);
            }
            const offset = self.attribute_bytes.items.len;
            self.attribute_bytes.appendSlice(self.allocator, name) catch
                return self.failOutOfMemory();
            self.attribute_bytes.appendSlice(self.allocator, value) catch
                return self.failOutOfMemory();
            self.attribute_records.append(self.allocator, .{
                .name_offset = offset,
                .name_len = name.len,
                .value_len = value.len,
                .start = self.token_start,
                .specified = false,
                .declared_type = self.dtd_state.declarations.attributes.items[declaration_index].attribute_type,
                .declaration_index = declaration_index,
            }) catch return self.failOutOfMemory();
        }

        fn rejectDuplicateAttributes(self: *Self) ReadError!void {
            const records = self.attribute_records.items;
            if (records.len <= linear_duplicate_threshold) {
                for (records, 0..) |record, index| {
                    for (records[0..index]) |previous| {
                        if (std.mem.eql(
                            u8,
                            self.attributeRawName(record),
                            self.attributeRawName(previous),
                        )) {
                            return self.failRelated(
                                .duplicate_attribute,
                                .invalid_xml,
                                record.start,
                                previous.start,
                            );
                        }
                    }
                }
                return;
            }

            std.sort.heap(
                AttributeRecord(config),
                records,
                self,
                attributeRecordNameLessThan,
            );
            for (records[1..], records[0 .. records.len - 1]) |record, previous| {
                if (std.mem.eql(
                    u8,
                    self.attributeRawName(record),
                    self.attributeRawName(previous),
                )) {
                    return self.failRelated(
                        .duplicate_attribute,
                        .invalid_xml,
                        record.start,
                        previous.start,
                    );
                }
            }
            std.sort.heap(
                AttributeRecord(config),
                records,
                {},
                attributeRecordSourceLessThan,
            );
        }

        fn attributeRecordNameLessThan(
            self: *Self,
            left: AttributeRecord(config),
            right: AttributeRecord(config),
        ) bool {
            return switch (std.mem.order(
                u8,
                self.attributeRawName(left),
                self.attributeRawName(right),
            )) {
                .lt => true,
                .gt => false,
                .eq => left.start.byte_offset < right.start.byte_offset,
            };
        }

        fn attributeRecordSourceLessThan(
            _: void,
            left: AttributeRecord(config),
            right: AttributeRecord(config),
        ) bool {
            return left.start.byte_offset < right.start.byte_offset;
        }

        fn attributeRawName(
            self: *const Self,
            record: AttributeRecord(config),
        ) []const u8 {
            return self.attribute_bytes.items[record.name_offset..][0..record.name_len];
        }

        fn compareAndConsumeEndName(self: *Self, run: []const u8) ReadError!void {
            const partial_remaining = std.math.sub(
                usize,
                self.options.limits.max_partial_token_bytes,
                self.token_name_len,
            ) catch unreachable;
            const qname_remaining = self.qnameRemaining(self.token_name_len);
            const accepted_len = @min(run.len, @min(partial_remaining, qname_remaining));
            const accepted = run[0..accepted_len];
            const raw = self.topRawName();
            if (self.end_mismatch_index == no_end_mismatch) {
                for (accepted, 0..) |byte, index| {
                    const name_index = self.token_name_len + index;
                    if (name_index >= raw.len or raw[name_index] != byte) {
                        self.end_mismatch_index = name_index;
                        self.end_mismatch_location = self.locationAfterInputPrefix(index);
                        break;
                    }
                }
            }
            self.token_name_len += accepted_len;
            self.consumeRun(accepted);
            if (accepted_len != run.len) {
                if (self.token_name_len == self.options.limits.max_partial_token_bytes) {
                    return self.failVoid(.partial_token_limit, .limit_exceeded);
                }
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
        }

        fn compareDecodedEndName(self: *Self, len: usize) ReadError!void {
            const remaining = self.options.limits.max_partial_token_bytes - self.token_name_len;
            if (len > remaining) {
                return self.failVoid(.partial_token_limit, .limit_exceeded);
            }
            if (len > self.qnameRemaining(self.token_name_len)) {
                return self.failVoid(.qname_limit, .limit_exceeded);
            }
            const raw = self.topRawName();
            if (self.end_mismatch_index == no_end_mismatch) {
                for (self.utf8_bytes[0..len], 0..) |byte, index| {
                    const name_index = self.token_name_len + index;
                    if (name_index >= raw.len or raw[name_index] != byte) {
                        self.end_mismatch_index = name_index;
                        self.end_mismatch_location = self.locationAfterSourceAdvances(
                            self.utf8_start,
                            self.utf8_source_advances[0..index],
                        );
                        break;
                    }
                }
            }
            self.token_name_len += len;
        }

        fn pendingUtf8ScalarLength(self: *const Self) error{InvalidUtf8}!usize {
            if (self.utf8_expected_len != 0) return self.utf8_expected_len;
            if (self.cursor == self.input.len) return error.InvalidUtf8;
            return utf8ExpectedLength(self.input[self.cursor]) orelse error.InvalidUtf8;
        }

        fn recordShortEndMismatch(self: *Self) void {
            if (self.end_mismatch_index == no_end_mismatch and
                self.token_name_len != self.topFrame().name_len)
            {
                self.end_mismatch_index = self.token_name_len;
                self.end_mismatch_location = self.currentLocation();
            }
        }

        fn finishEndElement(self: *Self) ReadError!void {
            if (self.end_mismatch_index != no_end_mismatch) {
                return self.failRelated(
                    .mismatched_end_tag,
                    .invalid_xml,
                    self.endMismatchLocation(),
                    self.topFrame().start,
                );
            }
            if (comptime config.profile.dtdMode() != .rejected) {
                if (self.dtd_state.entity_sources.items.len != 0) {
                    const source = self.dtd_state.entity_sources.items[
                        self.dtd_state.entity_sources.items.len - 1
                    ];
                    if (self.open_elements.items.len <= source.open_depth) {
                        return self.failAt(.malformed_reference, .invalid_xml, self.reference_start);
                    }
                }
            }
            if (comptime config.profile.dtdMode() == .validating) {
                if (self.validation_state.finishElement(
                    &self.open_elements.items[self.open_elements.items.len - 1].validation,
                    toValidationLocation(config, self.token_start),
                )) |issue| try self.reportValidity(issue, self.token_start);
            }
            self.vertical_state = .emit_end_element;
        }

        fn releaseTopElement(self: *Self) void {
            const frame = self.topFrame();
            self.open_elements.items.len -= 1;
            self.open_names.items.len = frame.name_offset;
            if (comptime config.profile.hasNamespaces()) {
                var binding_index = self.namespace_state.bindings.items.len;
                while (binding_index > frame.namespace_binding_mark) {
                    binding_index -= 1;
                    const binding = self.namespace_state.bindings.items[binding_index];
                    std.debug.assert(
                        self.namespace_state.active_prefixes.items[binding.active_index] ==
                            binding_index,
                    );
                    if (binding.previous_binding) |previous| {
                        self.namespace_state.active_prefixes.items[binding.active_index] = previous;
                    } else {
                        _ = self.namespace_state.active_prefixes.orderedRemove(binding.active_index);
                    }
                }
                self.namespace_state.bindings.items.len = frame.namespace_binding_mark;
                self.namespace_state.bytes.items.len = frame.namespace_byte_mark;
            }
        }

        fn topFrame(self: *const Self) OpenElementFrame(config) {
            std.debug.assert(self.open_elements.items.len > 0);
            return self.open_elements.items[self.open_elements.items.len - 1];
        }

        fn topRawName(self: *const Self) []const u8 {
            const frame = self.topFrame();
            return self.open_names.items[frame.name_offset..][0..frame.name_len];
        }

        fn startTagBytes(self: *const Self) usize {
            const byte_count = self.source_byte_offset - self.token_start.byte_offset;
            return std.math.cast(usize, byte_count) orelse std.math.maxInt(usize);
        }

        fn startTagRemaining(self: *const Self) usize {
            return std.math.sub(
                usize,
                self.options.limits.max_start_tag_bytes,
                self.startTagBytes(),
            ) catch 0;
        }

        fn requireStartTagByte(self: *Self) ReadError!void {
            if (self.startTagRemaining() == 0) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn consumeStartTagByte(self: *Self, byte: u8) void {
            std.debug.assert(self.startTagRemaining() > 0);
            self.consumeByte(byte);
        }

        fn consumeStartTagRun(self: *Self, run: []const u8) void {
            std.debug.assert(run.len <= self.startTagRemaining());
            self.consumeRun(run);
        }

        fn consumeStartTagWhitespaceRun(self: *Self) ReadError!void {
            const start = self.cursor;
            var end = start;
            while (end < self.input.len and isXmlWhitespace(self.input[end])) {
                end += 1;
            }
            const run = self.input[start..end];
            const accepted_len = @min(run.len, self.startTagRemaining());
            self.consumeStartTagRun(run[0..accepted_len]);
            if (accepted_len != run.len) {
                return self.failVoid(.start_tag_limit, .limit_exceeded);
            }
        }

        fn consumeByte(self: *Self, byte: u8) void {
            std.debug.assert(self.cursor < self.input.len);
            std.debug.assert(self.input[self.cursor] == byte);
            self.consumeRun(self.input[self.cursor .. self.cursor + 1]);
        }

        fn consumeWhitespaceRun(self: *Self) void {
            const start = self.cursor;
            var end = start;
            while (end < self.input.len and isXmlWhitespace(self.input[end])) {
                end += 1;
            }
            self.consumeRun(self.input[start..end]);
        }

        fn consumeRun(self: *Self, run: []const u8) void {
            std.debug.assert(run.len <= self.input.len - self.cursor);
            std.debug.assert(std.mem.eql(u8, run, self.input[self.cursor .. self.cursor + run.len]));

            var source_byte_offset = self.source_byte_offset;

            const direct_utf8 = self.inputUsesDirectOffsets();
            const source_advances = if (comptime config.profile.isUtf8Only())
                &.{}
            else if (direct_utf8)
                &.{}
            else
                self.source_state.source_advances.items[self.cursor..][0..run.len];
            const source_run_len: u64 = if (direct_utf8)
                run.len
            else
                sumSourceAdvances(source_advances);

            if (config.diagnostic_location == .line_column) {
                if (run.len > 0 and std.mem.indexOfAny(u8, run, "\r\n") == null) {
                    source_byte_offset += source_run_len;
                    self.position.pending_carriage_return = false;
                } else {
                    var line = self.position.line;
                    var line_start_offset = self.position.line_start_offset;
                    var pending_carriage_return = self.position.pending_carriage_return;
                    for (run, 0..) |byte, index| {
                        source_byte_offset += self.sourceAdvanceAt(index);
                        if (pending_carriage_return) {
                            pending_carriage_return = false;
                            if (byte == '\n') {
                                line_start_offset = source_byte_offset;
                                continue;
                            }
                        }
                        if (byte == '\r') {
                            line += 1;
                            line_start_offset = source_byte_offset;
                            pending_carriage_return = true;
                        } else if (byte == '\n') {
                            line += 1;
                            line_start_offset = source_byte_offset;
                        }
                    }
                    self.position.line = line;
                    self.position.line_start_offset = line_start_offset;
                    self.position.pending_carriage_return = pending_carriage_return;
                }
            } else {
                source_byte_offset += source_run_len;
            }

            self.cursor += run.len;
            self.source_byte_offset = source_byte_offset;
        }

        fn inputUsesDirectOffsets(self: *const Self) bool {
            if (comptime config.profile.isUtf8Only()) return true;
            return self.source_state.input_is_direct_utf8;
        }

        fn sourceAdvanceAt(self: *const Self, index: usize) u8 {
            if (comptime config.profile.isUtf8Only()) return 1;
            if (self.source_state.input_is_direct_utf8) return 1;
            return self.source_state.source_advances.items[self.cursor + index];
        }

        fn locationAfterInputPrefix(self: *const Self, len: usize) Location(config) {
            var location = self.currentLocation();
            for (0..len) |index| {
                const advance = self.sourceAdvanceAt(index);
                location.byte_offset += advance;
                if (config.diagnostic_location == .line_column) {
                    location.byte_column += advance;
                }
            }
            return location;
        }

        fn locationAfterSourceAdvances(
            self: *const Self,
            start: Location(config),
            advances: []const u8,
        ) Location(config) {
            _ = self;
            var location = start;
            for (advances) |advance| {
                location.byte_offset += advance;
                if (config.diagnostic_location == .line_column) {
                    location.byte_column += advance;
                }
            }
            return location;
        }

        fn validateTextFragment(self: *Self) ReadError!void {
            if (self.open_elements.items.len == 0 or self.text_fragment.len == 0) return;
            const frame = &self.open_elements.items[self.open_elements.items.len - 1].validation;
            const source = toValidationLocation(config, self.text_start);
            const whitespace = allXmlWhitespace(self.text_fragment);
            if (self.standalone_declared and self.standalone and whitespace and
                frame.declared_external and
                self.validation_state.isIgnorableWhitespace(frame.*, self.text_fragment))
            {
                try self.reportValidity(.{
                    .code = .standalone_external_whitespace,
                    .occurrence = source,
                }, self.text_start);
            }
            if (self.validation_state.text(
                &self.dtd_state.declarations,
                frame,
                self.text_fragment,
                self.text_origin == .character_data and !self.text_from_reference,
                source,
            )) |issue| try self.reportValidity(issue, self.text_start);
        }

        fn noteValidationContentMarker(self: *Self, location: Location(config)) ReadError!void {
            if (self.open_elements.items.len == 0) return;
            if (self.validation_state.contentMarker(
                &self.open_elements.items[self.open_elements.items.len - 1].validation,
                toValidationLocation(config, location),
            )) |issue| try self.reportValidity(issue, location);
        }

        fn textEvent(self: *const Self) Text(config) {
            if (comptime config.profile.dtdMode() == .validating) {
                const ignorable = self.open_elements.items.len != 0 and
                    self.text_origin == .character_data and !self.text_from_reference and
                    self.validation_state.isIgnorableWhitespace(
                        self.open_elements.items[self.open_elements.items.len - 1].validation,
                        self.text_fragment,
                    );
                return .{
                    .bytes = self.text_fragment,
                    .origin = self.text_origin,
                    .ignorable_whitespace = ignorable,
                };
            }
            return .{ .bytes = self.text_fragment, .origin = self.text_origin };
        }

        fn topName(self: *const Self) Name(config) {
            if (comptime config.profile.hasNamespaces()) {
                const raw = self.topRawName();
                return self.expandedName(
                    raw,
                    qnameParts(raw).?,
                    self.topFrame().namespace_reference,
                );
            }
            return nameFromRaw(config, self.topRawName());
        }

        fn startElement(self: *const Self, empty: bool) StartElement(config) {
            if (comptime config.profile.hasNamespaces()) {
                return .{
                    .name = self.topName(),
                    .attributes = self.event_attributes.items,
                    .namespace_declarations = self.namespace_state.event_declarations.items,
                    .empty_element_syntax = empty,
                };
            }
            return .{
                .name = self.topName(),
                .attributes = self.event_attributes.items,
                .empty_element_syntax = empty,
            };
        }

        fn endMismatchLocation(self: *const Self) Location(config) {
            std.debug.assert(self.end_mismatch_index != no_end_mismatch);
            return self.end_mismatch_location;
        }

        fn eventStep(
            self: *const Self,
            payload: EventPayload(config),
            start: Location(config),
            end: Location(config),
        ) Step(config) {
            _ = self;
            if (config.event_locations) {
                return .{ .event = .{
                    .payload = payload,
                    .span = .{ .start = start, .end = end },
                } };
            }
            return .{ .event = payload };
        }

        fn needInput(self: *Self) InternalReadError!Step(config) {
            std.debug.assert(!self.final_input);
            std.debug.assert(self.cursor == self.input.len);
            if (comptime config.profile.dtdMode() != .rejected) {
                if (self.dtd_state.entity_sources.items.len != 0) {
                    const current_frame = self.dtd_state.entity_sources.items[
                        self.dtd_state.entity_sources.items.len - 1
                    ];
                    if (comptime config.external_sources) {
                        if (current_frame.external and self.dtd_state.active_external != null) {
                            while (self.dtd_state.active_external != null) {
                                try self.refillExternalSource();
                                if (self.cursor < self.input.len) break;
                            }
                            if (self.cursor < self.input.len) return error.RefillDecodedInput;
                        }
                    }
                    if (self.vertical_state == .content_after_carriage_return) {
                        self.vertical_state = .content;
                        try self.prepareInlineText("\n", self.currentLocation());
                        return error.RefillDecodedInput;
                    }
                    if (self.open_elements.items.len != current_frame.open_depth or
                        self.vertical_state != current_frame.resume_state)
                    {
                        return self.failAt(
                            .malformed_reference,
                            .invalid_xml,
                            if (comptime config.external_sources)
                                if (current_frame.external) self.token_start else self.reference_start
                            else
                                self.reference_start,
                        );
                    }
                    if (comptime config.profile.isXml11() and config.external_sources) {
                        if (current_frame.external) try self.mergeSourceNormalization();
                    }
                    const frame = self.dtd_state.entity_sources.pop().?;
                    if (comptime config.profile.isXml11()) {
                        self.construct_started = false;
                        self.cdata_started = false;
                    }
                    if (comptime config.external_sources) {
                        if (frame.external) {
                            self.deinitSourceState(&self.source_state);
                            self.source_state = frame.source_state;
                            self.dtd_state.active_external = frame.active_external;
                            self.dtd_state.active_external_inclusion = frame.active_external_inclusion;
                            self.source_encoding = frame.source_encoding;
                        }
                    }
                    self.input = frame.input;
                    self.cursor = frame.cursor;
                    self.final_input = frame.final_input;
                    self.source_byte_offset = frame.source_byte_offset;
                    self.dtd_state.source_id = frame.source_id;
                    self.position = frame.position;
                    self.dtd_state.pending_entity_index = frame.entity_index;
                    self.dtd_state.current_is_replacement = frame.parent_is_replacement;
                    if (comptime config.report == .detailed) {
                        self.vertical_state = .emit_entity_end;
                    }
                    return error.RefillDecodedInput;
                }
            }
            self.input = &.{};
            self.cursor = 0;
            if (comptime !config.profile.isUtf8Only()) {
                try self.refillDecodedInput();
                if (self.input.len != 0 or self.final_input) {
                    return error.RefillDecodedInput;
                }
            }
            self.lifecycle = .needs_input;
            return .need_input;
        }

        fn refillExternalSource(self: *Self) ReadError!void {
            const source = self.dtd_state.active_external orelse return;
            const decoder = &self.source_state;
            self.input = &.{};
            self.cursor = 0;
            if ((decoder.raw_cursor == decoder.raw_input.len or decoder.external.needs_input) and
                !decoder.raw_final)
            {
                const pending = decoder.raw_input[decoder.raw_cursor..];
                if (pending.len != 0) {
                    std.mem.copyForwards(
                        u8,
                        decoder.external.raw.items[0..pending.len],
                        pending,
                    );
                }
                decoder.external.raw.items.len = pending.len;
                decoder.external.needs_input = false;
                while (true) {
                    const old_len = decoder.external.raw.items.len;
                    decoder.external.raw.ensureUnusedCapacity(self.allocator, 16 * 1024) catch
                        return self.failOutOfMemory();
                    decoder.external.raw.items.len = old_len + 16 * 1024;
                    const result = source.read(decoder.external.raw.items[old_len..]);
                    switch (result) {
                        .bytes => |len| {
                            decoder.external.raw.items.len = old_len + len;
                            if (len > self.options.resolver.max_source_bytes -|
                                (@as(usize, @intCast(decoder.raw_offset)) +| old_len) or
                                len > self.options.resolver.max_total_bytes -| self.dtd_state.external_resource_bytes)
                            {
                                return self.failAt(.external_resource_bytes_limit, .limit_exceeded, self.currentLocation());
                            }
                            self.dtd_state.external_resource_bytes += len;
                            if (decoder.encoding == .other or
                                !decoder.external.at_start or
                                externalRawStartReady(
                                    decoder.external.raw.items,
                                    source.encoding_hint,
                                    self.options.limits.max_partial_token_bytes,
                                )) break;
                        },
                        .end => {
                            decoder.external.raw.items.len = old_len;
                            decoder.raw_final = true;
                            decoder.external.eof = true;
                            source.close();
                            self.dtd_state.active_external = null;
                            break;
                        },
                        .io_failure => return self.failAt(.resolver_io_failure, .read_failed, self.currentLocation()),
                        .cancelled => return self.failAt(.resolver_cancelled, .cancelled, self.currentLocation()),
                    }
                    if (decoder.raw_final) break;
                }
                decoder.raw_input = decoder.external.raw.items;
                decoder.raw_cursor = 0;
                if (decoder.external.at_start and decoder.encoding == null) {
                    const detected = detectExternalRawEncoding(
                        decoder.raw_input,
                        source.encoding_hint,
                    ) orelse return self.failAt(.malformed_encoding, .invalid_xml, self.currentLocation());
                    decoder.encoding = detected.encoding;
                    self.source_encoding = detected.encoding;
                    decoder.raw_cursor = detected.signature_len;
                    decoder.raw_offset = detected.signature_len;
                    self.source_byte_offset = detected.signature_len;
                    if (config.diagnostic_location == .line_column) {
                        self.position.line_start_offset = self.source_byte_offset;
                    }
                }
            }
            try self.refillDecodedInput();
            if (decoder.external.at_start and self.input.len != 0) {
                if (externalTextDeclaration(self.input)) |declaration| {
                    if (self.xmlVersion() == .xml10 and declaration.version == .xml11) {
                        return self.failAt(.unsupported_version, .invalid_xml, self.currentLocation());
                    }
                    if (!externalEncodingMatches(self.source_encoding, declaration.encoding)) {
                        return self.failAt(.encoding_mismatch, .invalid_xml, self.currentLocation());
                    }
                    self.consumeRun(self.input[0..declaration.end]);
                } else if (malformedExternalTextDeclaration(self.input)) {
                    return self.failAt(.malformed_declaration, .invalid_xml, self.currentLocation());
                }
                decoder.external.at_start = false;
                if (comptime config.profile.isXml11()) {
                    if (self.xmlVersion() == .xml11) try self.activateXml11LineNormalization();
                }
            }
            try self.chargeExternalExpansion(self.input.len - self.cursor);
            if (self.final_input) self.final_input = false;
        }

        fn refillDecodedInput(self: *Self) ReadError!void {
            if (comptime config.profile.isUtf8Only()) unreachable;
            const source = &self.source_state;
            source.decoded.clearRetainingCapacity();
            source.source_advances.clearRetainingCapacity();
            source.input_is_direct_utf8 = false;

            if (source.failure) |failure| {
                return self.failAt(
                    failure.code,
                    failure.failure,
                    self.locationAtCurrentLine(failure.offset),
                );
            }

            const target_capacity = self.decodedTargetCapacity();
            while (source.decoded.items.len < target_capacity) {
                if (source.encoding == null) {
                    if (!self.detectSourceEncoding()) break;
                    if (source.failure != null) break;
                    continue;
                }
                switch (source.encoding.?) {
                    .utf8 => try self.decodeUtf8SourceRun(),
                    .utf16_le, .utf16_be => {
                        try self.ensureDecoderCapacity();
                        try self.decodeUtf16SourceRun();
                    },
                    .other => {
                        try self.decodeExternalOtherRun();
                        if (comptime config.profile.isXml11()) {
                            if (self.transcodedXml11LinesAreActive()) {
                                try self.normalizeTranscodedXml11Lines(0);
                            }
                        }
                        break;
                    },
                }
                if (self.input.len != 0) return;
                if ((source.encoding == .utf8 and source.decoded.items.len != 0) or
                    source.failure != null or
                    (comptime hasTranscoderState(config)) and source.external.needs_input or
                    source.raw_cursor == source.raw_input.len or
                    target_capacity - source.decoded.items.len < 4)
                {
                    break;
                }
            }

            if (source.decoded.items.len != 0) {
                self.input = source.decoded.items;
                return;
            }
            if (source.failure) |failure| {
                return self.failAt(
                    failure.code,
                    failure.failure,
                    self.locationAtCurrentLine(failure.offset),
                );
            }
            if (source.raw_cursor != source.raw_input.len) return;
            if (!source.raw_final) {
                source.raw_input = &.{};
                source.raw_cursor = 0;
                return;
            }
            if (source.encoding == null) _ = self.finishEncodingDetection();
            if (source.encoding == .utf16_le or source.encoding == .utf16_be) {
                if (source.pending_byte != null) {
                    return self.failAt(
                        .malformed_encoding,
                        .invalid_xml,
                        self.locationAtCurrentLine(source.pending_byte_offset),
                    );
                }
                if (source.high_surrogate != null) {
                    return self.failAt(
                        .malformed_encoding,
                        .invalid_xml,
                        self.locationAtCurrentLine(source.high_surrogate_offset),
                    );
                }
            }
            self.final_input = true;
        }

        fn detectSourceEncoding(self: *Self) bool {
            const source = &self.source_state;
            while (source.raw_cursor < source.raw_input.len and source.encoding == null and
                source.failure == null)
            {
                const byte = source.raw_input[source.raw_cursor];
                source.raw_cursor += 1;
                source.raw_offset += 1;
                source.signature_bytes[source.signature_len] = byte;
                source.signature_len += 1;

                if (source.signature_len == 1) {
                    if (byte != 0 and byte != '<' and byte != 0x4c and
                        byte != 0xef and byte != 0xfe and byte != 0xff)
                    {
                        self.selectSourceEncoding(.utf8, 0);
                    }
                } else if (source.signature_len == 2) {
                    const signature = source.signature_bytes[0..2];
                    if (!std.mem.eql(u8, signature, "\xfe\xff") and
                        !std.mem.eql(u8, signature, "\xff\xfe") and
                        !std.mem.eql(u8, signature, "\xef\xbb") and
                        signature[0] != 0 and
                        !std.mem.eql(u8, signature, "\x3c\x00") and
                        !std.mem.eql(u8, signature, "\x4c\x6f"))
                    {
                        self.selectSourceEncoding(.utf8, 0);
                    }
                } else if (source.signature_len == 3) {
                    const signature = source.signature_bytes[0..3];
                    if (std.mem.eql(u8, signature, "\xef\xbb\xbf")) {
                        self.selectSourceEncoding(.utf8, 3);
                    } else if (std.mem.startsWith(u8, signature, "\xfe\xff")) {
                        if (signature[2] != 0) self.selectSourceEncoding(.utf16_be, 2);
                    } else if (std.mem.startsWith(u8, signature, "\xff\xfe")) {
                        if (signature[2] != 0) self.selectSourceEncoding(.utf16_le, 2);
                    } else if (signature[0] != 0 and
                        !std.mem.startsWith(u8, signature, "\x3c\x00") and
                        !std.mem.eql(u8, signature, "\x4c\x6f\xa7"))
                    {
                        self.selectSourceEncoding(.utf8, 0);
                    }
                } else if (isUnsupportedFourByteSignature(source.signature_bytes)) {
                    source.failure = .{
                        .code = .unsupported_encoding,
                        .offset = 0,
                        .failure = .unsupported_feature,
                    };
                } else if (std.mem.eql(u8, &source.signature_bytes, "\x00\x3c\x00\x3f") or
                    std.mem.eql(u8, &source.signature_bytes, "\x3c\x00\x3f\x00"))
                {
                    source.failure = .{
                        .code = .missing_encoding_signature,
                        .offset = 0,
                    };
                } else if (std.mem.eql(u8, &source.signature_bytes, "\x4c\x6f\xa7\x94")) {
                    source.failure = .{
                        .code = .unsupported_encoding,
                        .offset = 0,
                        .failure = .unsupported_feature,
                    };
                } else if (std.mem.startsWith(u8, &source.signature_bytes, "\xfe\xff")) {
                    self.selectSourceEncoding(.utf16_be, 2);
                } else if (std.mem.startsWith(u8, &source.signature_bytes, "\xff\xfe")) {
                    self.selectSourceEncoding(.utf16_le, 2);
                } else {
                    self.selectSourceEncoding(.utf8, 0);
                }
            }
            if (source.encoding == null and source.raw_final and
                source.raw_cursor == source.raw_input.len)
            {
                return self.finishEncodingDetection();
            }
            return source.encoding != null or source.failure != null;
        }

        fn finishEncodingDetection(self: *Self) bool {
            if (comptime config.profile.isUtf8Only()) unreachable;
            if (self.source_state.encoding == null) {
                const signature = self.source_state.signature_bytes[0..self.source_state.signature_len];
                if (std.mem.startsWith(u8, signature, "\xfe\xff")) {
                    self.selectSourceEncoding(.utf16_be, 2);
                } else if (std.mem.startsWith(u8, signature, "\xff\xfe")) {
                    self.selectSourceEncoding(.utf16_le, 2);
                } else {
                    self.selectSourceEncoding(.utf8, 0);
                }
            }
            return true;
        }

        fn selectSourceEncoding(
            self: *Self,
            encoding: SourceEncoding,
            signature_len: usize,
        ) void {
            const source = &self.source_state;
            source.encoding = encoding;
            self.source_encoding = encoding;
            if (signature_len != 0) {
                self.source_byte_offset = signature_len;
                if (config.diagnostic_location == .line_column) {
                    self.position.line_start_offset = self.source_byte_offset;
                }
                const trailing_len = source.signature_len - signature_len;
                if (trailing_len != 0) {
                    std.mem.copyForwards(
                        u8,
                        source.signature_bytes[0..trailing_len],
                        source.signature_bytes[signature_len..source.signature_len],
                    );
                }
                source.signature_len = trailing_len;
            }
        }

        fn activateXml11LineNormalization(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) unreachable;
            const source = &self.source_state;
            if (self.cursor == self.input.len) return;
            if (self.source_encoding == .other) {
                try self.normalizeTranscodedXml11Lines(self.cursor);
                self.input = source.decoded.items;
                self.cursor = 0;
                return;
            }
            if (self.source_encoding == .utf8 and source.input_is_direct_utf8) {
                const remaining = self.input[self.cursor..];
                source.raw_input = remaining;
                source.raw_cursor = 0;
                source.raw_offset -= remaining.len;
                source.decoded.clearRetainingCapacity();
                source.source_advances.clearRetainingCapacity();
                self.input = &.{};
                self.cursor = 0;
                source.input_is_direct_utf8 = false;
                try self.decodeXml11Utf8Run();
                self.input = source.decoded.items;
                return;
            }

            var read = self.cursor;
            var write: usize = 0;
            while (read < self.input.len) {
                const line_len: usize = if (std.mem.startsWith(u8, self.input[read..], "\xc2\x85"))
                    2
                else if (std.mem.startsWith(u8, self.input[read..], "\xe2\x80\xa8"))
                    3
                else
                    0;
                if (line_len == 0) {
                    source.decoded.items[write] = self.input[read];
                    source.source_advances.items[write] = source.source_advances.items[read];
                    write += 1;
                    read += 1;
                    continue;
                }
                var advance: u8 = 0;
                for (source.source_advances.items[read..][0..line_len]) |value| advance += value;
                source.decoded.items[write] = '\n';
                source.source_advances.items[write] = advance;
                write += 1;
                read += line_len;
            }
            source.decoded.items.len = write;
            source.source_advances.items.len = write;
            self.input = source.decoded.items;
            self.cursor = 0;
            source.input_is_direct_utf8 = false;
        }

        fn decodeUtf8SourceRun(self: *Self) ReadError!void {
            const source = &self.source_state;
            if (source.signature_len != 0) {
                self.input = source.signature_bytes[0..source.signature_len];
                if (comptime config.profile.isXml11()) {
                    const base = source.raw_offset - source.signature_len;
                    for (self.input, 0..) |byte, index| {
                        try self.scanSourceRawUtf8Byte(byte, base + @as(u64, @intCast(index)));
                    }
                }
                source.signature_len = 0;
                source.input_is_direct_utf8 = true;
                return;
            }
            if (comptime config.profile.isXml11()) {
                const external_declaration = if (comptime config.external_sources)
                    self.dtd_state.active_external != null and source.external.at_start
                else
                    false;
                if (self.xmlVersion() == .xml11 and !external_declaration) {
                    try self.decodeXml11Utf8Run();
                    return;
                }
            }
            if (source.raw_cursor < source.raw_input.len) {
                const start = source.raw_offset;
                self.input = source.raw_input[source.raw_cursor..];
                if (comptime config.profile.isXml11()) {
                    for (self.input, 0..) |byte, index| {
                        try self.scanSourceRawUtf8Byte(byte, start + @as(u64, @intCast(index)));
                    }
                }
                source.raw_offset += self.input.len;
                source.raw_cursor = source.raw_input.len;
                source.input_is_direct_utf8 = true;
            }
        }

        fn decodeXml11Utf8Run(self: *Self) ReadError!void {
            if (comptime !config.profile.isXml11()) unreachable;
            const source = &self.source_state;
            try self.ensureDecoderCapacity();
            const target_capacity = self.decodedTargetCapacity();
            while (source.decoded.items.len + 3 <= target_capacity) {
                if (source.line_pending_len == 0) {
                    if (source.raw_cursor == source.raw_input.len) break;
                    const byte = source.raw_input[source.raw_cursor];
                    try self.scanSourceRawUtf8Byte(byte, source.raw_offset);
                    source.raw_cursor += 1;
                    source.raw_offset += 1;
                    if (byte == 0xc2 or byte == 0xe2) {
                        source.line_pending[0] = byte;
                        source.line_pending_len = 1;
                    } else {
                        self.appendDecodedByte(byte, 1);
                    }
                    continue;
                }
                if (source.raw_cursor == source.raw_input.len) {
                    if (!source.raw_final) break;
                    for (source.line_pending[0..source.line_pending_len]) |byte| {
                        self.appendDecodedByte(byte, 1);
                    }
                    source.line_pending_len = 0;
                    break;
                }
                const byte = source.raw_input[source.raw_cursor];
                try self.scanSourceRawUtf8Byte(byte, source.raw_offset);
                source.raw_cursor += 1;
                source.raw_offset += 1;
                source.line_pending[source.line_pending_len] = byte;
                source.line_pending_len += 1;

                const pending = source.line_pending[0..source.line_pending_len];
                const complete_nel = pending.len == 2 and std.mem.eql(u8, pending, "\xc2\x85");
                const complete_separator = pending.len == 3 and
                    std.mem.eql(u8, pending, "\xe2\x80\xa8");
                const possible_separator = pending[0] == 0xe2 and
                    (pending.len == 1 or (pending.len == 2 and pending[1] == 0x80));
                if (complete_nel or complete_separator) {
                    self.appendDecodedByte('\n', @intCast(pending.len));
                    source.line_pending_len = 0;
                } else if ((pending[0] == 0xc2 and pending.len == 2) or
                    (pending[0] == 0xe2 and !possible_separator))
                {
                    for (pending) |pending_byte| self.appendDecodedByte(pending_byte, 1);
                    source.line_pending_len = 0;
                }
            }
        }

        fn decodeUtf16SourceRun(self: *Self) ReadError!void {
            const source = &self.source_state;
            const target_capacity = self.decodedTargetCapacity();
            while (source.decoded.items.len + 4 <= target_capacity and
                (source.signature_len != 0 or source.raw_cursor < source.raw_input.len))
            {
                const byte, const byte_offset = if (source.signature_len != 0) replay: {
                    const replay_offset = source.raw_offset - source.signature_len;
                    const replay_byte = source.signature_bytes[0];
                    if (source.signature_len > 1) {
                        std.mem.copyForwards(
                            u8,
                            source.signature_bytes[0 .. source.signature_len - 1],
                            source.signature_bytes[1..source.signature_len],
                        );
                    }
                    source.signature_len -= 1;
                    break :replay .{ replay_byte, replay_offset };
                } else raw: {
                    const raw_byte = source.raw_input[source.raw_cursor];
                    const raw_offset = source.raw_offset;
                    source.raw_cursor += 1;
                    source.raw_offset += 1;
                    break :raw .{ raw_byte, raw_offset };
                };
                if (source.pending_byte == null) {
                    source.pending_byte = byte;
                    source.pending_byte_offset = byte_offset;
                    continue;
                }
                const first = source.pending_byte.?;
                const unit_offset = source.pending_byte_offset;
                source.pending_byte = null;
                const unit = switch (source.encoding.?) {
                    .utf16_le => @as(u16, first) | (@as(u16, byte) << 8),
                    .utf16_be => (@as(u16, first) << 8) | @as(u16, byte),
                    .utf8, .other => unreachable,
                };
                if (source.high_surrogate) |high| {
                    if (unit < 0xdc00 or unit > 0xdfff) {
                        source.failure = .{
                            .code = .malformed_encoding,
                            .offset = source.high_surrogate_offset,
                        };
                        return;
                    }
                    const high_value = @as(u32, high) - 0xd800;
                    const low_value = @as(u32, unit) - 0xdc00;
                    const codepoint: u21 = @intCast(0x10000 + (high_value << 10) + low_value);
                    source.high_surrogate = null;
                    try self.scanSourceScalar(codepoint, source.high_surrogate_offset, 4);
                    self.appendDecodedScalar(codepoint, 4);
                } else if (unit >= 0xd800 and unit <= 0xdbff) {
                    source.high_surrogate = unit;
                    source.high_surrogate_offset = unit_offset;
                } else if (unit >= 0xdc00 and unit <= 0xdfff) {
                    source.failure = .{ .code = .malformed_encoding, .offset = unit_offset };
                    return;
                } else {
                    try self.scanSourceScalar(@intCast(unit), unit_offset, 2);
                    self.appendDecodedScalar(@intCast(unit), 2);
                }
            }
        }

        fn decodeExternalOtherRun(self: *Self) ReadError!void {
            if (comptime !hasTranscoderState(config)) {
                return self.failAt(.unsupported_encoding, .unsupported_feature, self.currentLocation());
            }
            const source = &self.source_state;
            if (source.external.finished) return;
            if (source.external.needs_input) return;
            const converter = source.external.transcoder orelse
                return self.failAt(.unsupported_encoding, .unsupported_feature, self.currentLocation());
            try self.ensureDecoderCapacity();
            const pending_len = if (comptime config.profile.isXml11())
                source.line_pending_len
            else
                0;
            const output_limit = self.decodedTargetCapacity() - pending_len;
            decode: while (source.decoded.items.len < output_limit) {
                const output = source.decoded.allocatedSlice()[source.decoded.items.len..output_limit];
                const source_advances = source.source_advances.allocatedSlice()[source.source_advances.items.len..output_limit];
                const remaining = source.raw_input[source.raw_cursor..];
                const bounded_input = remaining[0..@min(remaining.len, transcoder_input_capacity)];
                const final = source.raw_final and bounded_input.len == remaining.len;
                const step = converter.run(
                    bounded_input,
                    final,
                    output,
                    source_advances,
                ) catch return self.failAt(
                    .malformed_encoding,
                    .invalid_xml,
                    self.locationAtCurrentLine(source.raw_offset),
                );
                switch (step) {
                    .progress => |progress| {
                        source.external.needs_input = false;
                        const raw_start = source.raw_offset;
                        source.raw_cursor += progress.consumed;
                        source.raw_offset += progress.consumed;
                        const old_len = source.decoded.items.len;
                        source.decoded.items.len += progress.produced;
                        source.source_advances.items.len = old_len + progress.produced;
                        if (comptime config.profile.isXml11()) {
                            var mapped_offset = raw_start;
                            for (
                                source.decoded.items[old_len..][0..progress.produced],
                                source.source_advances.items[old_len..][0..progress.produced],
                            ) |byte, advance| {
                                try self.scanSourceUtf8Byte(byte, mapped_offset, advance);
                                mapped_offset += advance;
                            }
                        }
                    },
                    .need_input => {
                        if (final) {
                            source.external.finished = true;
                        } else if (bounded_input.len == transcoder_input_capacity) {
                            return self.failAt(
                                .malformed_encoding,
                                .invalid_xml,
                                self.locationAtCurrentLine(source.raw_offset),
                            );
                        } else {
                            source.external.needs_input = true;
                        }
                        break :decode;
                    },
                    .need_output => {
                        if (source.decoded.items.len == 0) {
                            return self.failAt(
                                .malformed_encoding,
                                .invalid_xml,
                                self.locationAtCurrentLine(source.raw_offset),
                            );
                        }
                        break :decode;
                    },
                    .malformed => |offset| return self.failAt(
                        .malformed_encoding,
                        .invalid_xml,
                        self.locationAtCurrentLine(source.raw_offset + offset),
                    ),
                    .unsupported => return self.failAt(
                        .unsupported_encoding,
                        .unsupported_feature,
                        self.locationAtCurrentLine(source.raw_offset),
                    ),
                    .cancelled => return self.failAt(
                        .transcoder_cancelled,
                        .cancelled,
                        self.locationAtCurrentLine(source.raw_offset),
                    ),
                }
                if (source.raw_cursor == source.raw_input.len and !source.raw_final) break;
                if (source.raw_final and source.raw_cursor == source.raw_input.len and
                    source.decoded.items.len == 0) break;
            }
        }

        fn transcodedXml11LinesAreActive(self: *const Self) bool {
            if (comptime !config.profile.isXml11()) return false;
            if (self.xmlVersion() != .xml11) return false;
            if (comptime config.profile.dtdMode() == .rejected) return true;
            if (self.dtd_state.current_is_replacement) return false;
            return self.dtd_state.active_external == null or
                !self.source_state.external.at_start;
        }

        fn normalizeTranscodedXml11Lines(self: *Self, start: usize) ReadError!void {
            if (comptime !config.profile.isXml11() or !hasTranscoderState(config)) unreachable;
            const source = &self.source_state;
            std.debug.assert(start <= source.decoded.items.len);
            std.debug.assert(source.decoded.items.len == source.source_advances.items.len);

            const remaining_len = source.decoded.items.len - start;
            if (start != 0) {
                std.mem.copyForwards(
                    u8,
                    source.decoded.items[0..remaining_len],
                    source.decoded.items[start..],
                );
                std.mem.copyForwards(
                    u8,
                    source.source_advances.items[0..remaining_len],
                    source.source_advances.items[start..],
                );
                source.decoded.items.len = remaining_len;
                source.source_advances.items.len = remaining_len;
            }

            const pending_len: usize = source.line_pending_len;
            if (pending_len != 0) {
                const combined_len = pending_len + source.decoded.items.len;
                std.debug.assert(combined_len <= source.decoded.capacity);
                std.debug.assert(combined_len <= source.source_advances.capacity);
                const decoded_len = source.decoded.items.len;
                source.decoded.items.len = combined_len;
                source.source_advances.items.len = combined_len;
                std.mem.copyBackwards(
                    u8,
                    source.decoded.items[pending_len..],
                    source.decoded.items[0..decoded_len],
                );
                std.mem.copyBackwards(
                    u8,
                    source.source_advances.items[pending_len..],
                    source.source_advances.items[0..decoded_len],
                );
                @memcpy(
                    source.decoded.items[0..pending_len],
                    source.line_pending[0..pending_len],
                );
                @memcpy(
                    source.source_advances.items[0..pending_len],
                    source.line_pending_advances[0..pending_len],
                );
                source.line_pending_len = 0;
            }

            var read: usize = 0;
            var write: usize = 0;
            while (read < source.decoded.items.len) {
                const bytes = source.decoded.items[read..];
                const line_len: usize = if (std.mem.startsWith(u8, bytes, "\xc2\x85"))
                    2
                else if (std.mem.startsWith(u8, bytes, "\xe2\x80\xa8"))
                    3
                else
                    0;
                if (line_len != 0) {
                    var source_advance: u8 = 0;
                    for (source.source_advances.items[read..][0..line_len]) |advance| {
                        source_advance = std.math.add(u8, source_advance, advance) catch
                            return self.failAt(
                                .malformed_encoding,
                                .invalid_xml,
                                self.locationAtCurrentLine(self.source_byte_offset),
                            );
                    }
                    source.decoded.items[write] = '\n';
                    source.source_advances.items[write] = source_advance;
                    write += 1;
                    read += line_len;
                    continue;
                }

                const pending: usize = if (bytes.len == 1 and
                    (bytes[0] == 0xc2 or bytes[0] == 0xe2))
                    1
                else if (bytes.len == 2 and bytes[0] == 0xe2 and bytes[1] == 0x80)
                    2
                else
                    0;
                if (pending != 0 and !source.external.finished) {
                    @memcpy(
                        source.line_pending[0..pending],
                        source.decoded.items[read..][0..pending],
                    );
                    @memcpy(
                        source.line_pending_advances[0..pending],
                        source.source_advances.items[read..][0..pending],
                    );
                    source.line_pending_len = @intCast(pending);
                    break;
                }

                source.decoded.items[write] = source.decoded.items[read];
                source.source_advances.items[write] = source.source_advances.items[read];
                write += 1;
                read += 1;
            }
            source.decoded.items.len = write;
            source.source_advances.items.len = write;
        }

        fn ensureDecoderCapacity(self: *Self) ReadError!void {
            const source = &self.source_state;
            const target_capacity = self.decodedTargetCapacity();
            source.decoded.ensureTotalCapacityPrecise(
                self.allocator,
                target_capacity,
            ) catch return self.failOutOfMemory();
            source.source_advances.ensureTotalCapacityPrecise(
                self.allocator,
                target_capacity,
            ) catch return self.failOutOfMemory();
        }

        fn decodedTargetCapacity(self: *const Self) usize {
            if (comptime !config.external_sources) return decoded_input_capacity;
            return if (self.dtd_state.active_external != null and self.source_state.external.at_start)
                @max(decoded_input_capacity, self.options.limits.max_partial_token_bytes)
            else
                decoded_input_capacity;
        }

        fn appendDecodedScalar(self: *Self, codepoint: u21, source_len: u8) void {
            if (comptime config.profile.isXml11()) {
                const external_declaration = if (comptime config.external_sources)
                    self.dtd_state.active_external != null and self.source_state.external.at_start
                else
                    false;
                if (self.xmlVersion() == .xml11 and !external_declaration and
                    (codepoint == 0x85 or codepoint == 0x2028))
                {
                    self.appendDecodedByte('\n', source_len);
                    return;
                }
            }
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
            for (bytes[0..len], 0..) |byte, index| {
                self.appendDecodedByte(byte, if (index + 1 == len) source_len else 0);
            }
        }

        fn appendDecodedByte(self: *Self, byte: u8, source_advance: u8) void {
            self.source_state.decoded.appendAssumeCapacity(byte);
            self.source_state.source_advances.appendAssumeCapacity(source_advance);
        }

        fn locationAtCurrentLine(self: *const Self, offset: u64) Location(config) {
            var location = self.currentLocation();
            location.byte_offset = offset;
            if (config.diagnostic_location == .line_column) {
                location.byte_column = offset - self.position.line_start_offset + 1;
            }
            return location;
        }

        fn fail(self: *Self, code: DiagnosticCode, failure: Failure) ReadError {
            return self.failAt(code, failure, self.currentLocation());
        }

        fn reportValidity(
            self: *Self,
            issue: validation_module.Issue,
            fallback: Location(config),
        ) ReadError!void {
            if (self.validation_parameter_entity_skipped) switch (issue.code) {
                .missing_doctype, .root_name_mismatch => {},
                else => return,
            } else if (self.validation_declarations_incomplete) switch (issue.code) {
                .undeclared_element,
                .undeclared_attribute,
                .undeclared_entity,
                .undeclared_notation,
                => return,
                else => {},
            };
            if (self.validation_incomplete and issue.code == .unresolved_idref) return;
            return self.emitValidity(issue, fallback);
        }

        fn emitValidity(
            self: *Self,
            issue: validation_module.Issue,
            fallback: Location(config),
        ) ReadError!void {
            if (self.validity_errors == self.options.validation.limits.max_errors) {
                return;
            }
            const primary = if (issue.occurrence) |location|
                validationLocation(config, location)
            else if (issue.declaration) |location|
                if (location.source_id == 0)
                    self.dtdLocation(location.offset)
                else
                    self.dtdSourceLocation(location.source_id, location.offset)
            else
                fallback;
            const related = if (issue.related) |location|
                if (location.source_id == 0)
                    self.dtdLocation(location.offset)
                else
                    self.dtdSourceLocation(location.source_id, location.offset)
            else
                null;
            const inclusion_trace = if (comptime config.external_sources)
                self.captureInclusionTrace(primary.source_id)
            else {};
            const diagnostic_value: Diagnostic(config) = .{
                .code = validityDiagnosticCode(issue.code),
                .primary = primary,
                .related = related,
                .inclusion_trace = inclusion_trace,
            };
            if (self.first_diagnostic == null) self.first_diagnostic = diagnostic_value;
            self.validity_errors += 1;
            if (self.options.validation.sink) |sink| {
                if (sink.report(diagnostic_value) == .cancel) {
                    self.closeExternalSources();
                    self.failure = .cancelled;
                    self.lifecycle = .failed;
                    return error.Cancelled;
                }
            }
            if (!self.options.validation.collect_validity_errors) {
                self.closeExternalSources();
                self.failure = .not_valid;
                self.lifecycle = .failed;
                return error.NotValid;
            }
        }

        fn failAt(
            self: *Self,
            code: DiagnosticCode,
            failure: Failure,
            primary: Location(config),
        ) ReadError {
            const inclusion_trace = if (comptime config.external_sources)
                self.captureInclusionTrace(primary.source_id)
            else {};
            self.closeExternalSources();
            self.first_diagnostic = .{
                .code = code,
                .primary = primary,
                .inclusion_trace = inclusion_trace,
            };
            self.failure = failure;
            self.lifecycle = .failed;
            return failureToError(failure);
        }

        fn failRelated(
            self: *Self,
            code: DiagnosticCode,
            failure: Failure,
            primary: Location(config),
            related: Location(config),
        ) ReadError {
            const inclusion_trace = if (comptime config.external_sources)
                self.captureInclusionTrace(primary.source_id)
            else {};
            self.closeExternalSources();
            self.first_diagnostic = .{
                .code = code,
                .primary = primary,
                .related = related,
                .inclusion_trace = inclusion_trace,
            };
            self.failure = failure;
            self.lifecycle = .failed;
            return failureToError(failure);
        }

        fn failVoid(self: *Self, code: DiagnosticCode, failure: Failure) ReadError {
            return self.fail(code, failure);
        }

        fn failOutOfMemory(self: *Self) ReadError {
            self.closeExternalSources();
            self.failure = .out_of_memory;
            self.lifecycle = .failed;
            return error.OutOfMemory;
        }

        fn closeExternalSources(self: *Self) void {
            if (comptime config.profile.dtdMode() == .rejected or !config.external_sources) return;
            if (self.dtd_state.active_external) |source| source.close();
            self.dtd_state.active_external = null;
            self.dtd_state.active_external_inclusion = null;
            for (self.dtd_state.entity_sources.items) |*frame| {
                if (frame.active_external) |source| source.close();
                frame.active_external = null;
            }
        }

        fn captureInclusionTrace(self: *Self, primary_source_id: u32) []const Location(config) {
            if (comptime !config.external_sources) unreachable;
            self.diagnostic_inclusions.clearRetainingCapacity();
            const max_depth = self.options.dtd_limits.max_active_entity_depth;
            if (primary_source_id == self.dtd_state.source_id and
                self.dtd_state.active_external_inclusion != null)
            {
                self.diagnostic_inclusions.appendAssumeCapacity(
                    self.dtd_state.active_external_inclusion.?,
                );
                var index = self.dtd_state.entity_sources.items.len;
                while (index != 0 and self.diagnostic_inclusions.items.len < max_depth) {
                    index -= 1;
                    if (self.dtd_state.entity_sources.items[index].active_external_inclusion) |location| {
                        self.diagnostic_inclusions.appendAssumeCapacity(location);
                    }
                }
                return self.diagnostic_inclusions.items;
            }

            var source_id = primary_source_id;
            while (source_id != 0 and self.diagnostic_inclusions.items.len < max_depth) {
                var found: ?ExternalBuffer = null;
                var index = self.dtd_state.external_buffers.items.len;
                while (index != 0) {
                    index -= 1;
                    const buffer = self.dtd_state.external_buffers.items[index];
                    if (buffer.source_id == source_id) {
                        found = buffer;
                        break;
                    }
                }
                const buffer = found orelse break;
                var location = locationFromSource(
                    config,
                    buffer.inclusion_source_id,
                    buffer.inclusion_offset,
                );
                if (config.diagnostic_location == .line_column) {
                    location.line = buffer.inclusion_line;
                    location.byte_column = buffer.inclusion_column;
                }
                self.diagnostic_inclusions.appendAssumeCapacity(location);
                source_id = buffer.inclusion_source_id;
            }
            if (comptime config.profile.dtdMode() == .validating) {
                if (self.diagnostic_inclusions.items.len == 0) {
                    const external = self.options.validation.external_subset orelse
                        return self.diagnostic_inclusions.items;
                    source_id = primary_source_id;
                    while (source_id != 0 and self.diagnostic_inclusions.items.len < max_depth) {
                        const inclusion = external.sourceInclusion(source_id) orelse {
                            if (external.hasSource(source_id)) {
                                self.diagnostic_inclusions.appendAssumeCapacity(self.dtdLocation(0));
                            }
                            break;
                        };
                        self.diagnostic_inclusions.appendAssumeCapacity(
                            self.dtdSourceLocation(inclusion.source_id, inclusion.offset),
                        );
                        source_id = inclusion.source_id;
                    }
                }
            }
            return self.diagnostic_inclusions.items;
        }

        fn failureError(self: *const Self) ReadError {
            return failureToError(self.failure orelse unreachable);
        }

        fn currentLocation(self: *const Self) Location(config) {
            if (config.diagnostic_location == .line_column) {
                return .{
                    .byte_offset = self.source_byte_offset,
                    .source_id = if (comptime config.profile.dtdMode() == .rejected)
                        0
                    else
                        self.dtd_state.source_id,
                    .line = self.position.line,
                    .byte_column = self.source_byte_offset - self.position.line_start_offset + 1,
                };
            }
            return .{
                .byte_offset = self.source_byte_offset,
                .source_id = if (comptime config.profile.dtdMode() == .rejected)
                    0
                else
                    self.dtd_state.source_id,
            };
        }
    };
}

const ParsedDeclaration = struct {
    version_offset: usize,
    version_len: usize,
    effective_version: XmlVersion,
    encoding_offset: usize = 0,
    encoding_len: usize = 0,
    standalone: bool = false,
    standalone_declared: bool = false,
};

const DeclarationParse = union(enum) {
    parsed: ParsedDeclaration,
    malformed: usize,
    unsupported_version: usize,
    unsupported_encoding: usize,
    encoding_mismatch: usize,
};

const ByteRange = struct {
    offset: usize,
    len: usize,
};

fn parseXmlDeclaration(
    bytes: []const u8,
    source_encoding: SourceEncoding,
    supports_utf16: bool,
    supports_xml11: bool,
) DeclarationParse {
    var index: usize = 0;
    if (!skipRequiredXmlWhitespace(bytes, &index)) return .{ .malformed = index };
    if (!consumeLiteral(bytes, &index, "version")) return .{ .malformed = index };
    if (!consumeEquals(bytes, &index)) return .{ .malformed = index };
    const version = consumeQuoted(bytes, &index) orelse return .{ .malformed = index };
    const version_bytes = bytes[version.offset..][0..version.len];
    if (!isXml10VersionNumber(version_bytes)) {
        if (isDottedVersionNumber(version_bytes)) {
            return .{ .unsupported_version = version.offset };
        }
        return .{ .malformed = version.offset };
    }

    var parsed: ParsedDeclaration = .{
        .version_offset = version.offset,
        .version_len = version.len,
        .effective_version = if (supports_xml11 and std.mem.eql(u8, version_bytes, "1.1"))
            .xml11
        else
            .xml10,
    };
    if (index == bytes.len) return .{ .parsed = parsed };
    if (!skipRequiredXmlWhitespace(bytes, &index)) return .{ .malformed = index };
    if (index == bytes.len) return .{ .parsed = parsed };

    if (startsWithLiteral(bytes, index, "encoding")) {
        _ = consumeLiteral(bytes, &index, "encoding");
        if (!consumeEquals(bytes, &index)) return .{ .malformed = index };
        const encoding = consumeQuoted(bytes, &index) orelse return .{ .malformed = index };
        const encoding_bytes = bytes[encoding.offset..][0..encoding.len];
        if (!isEncodingName(encoding_bytes)) return .{ .malformed = encoding.offset };
        if (source_encoding != .other) {
            if (!supports_utf16 and !std.ascii.eqlIgnoreCase(encoding_bytes, "UTF-8")) {
                return .{ .unsupported_encoding = encoding.offset };
            }
            const declared_encoding: ?SourceEncoding = if (std.ascii.eqlIgnoreCase(
                encoding_bytes,
                "UTF-8",
            ))
                .utf8
            else if (std.ascii.eqlIgnoreCase(encoding_bytes, "UTF-16"))
                switch (source_encoding) {
                    .utf16_le => .utf16_le,
                    .utf16_be => .utf16_be,
                    .utf8, .other => null,
                }
            else if (std.ascii.eqlIgnoreCase(encoding_bytes, "UTF-16LE"))
                .utf16_le
            else if (std.ascii.eqlIgnoreCase(encoding_bytes, "UTF-16BE"))
                .utf16_be
            else
                return .{ .unsupported_encoding = encoding.offset };
            if (declared_encoding == null or declared_encoding.? != source_encoding) {
                return .{ .encoding_mismatch = encoding.offset };
            }
        }
        parsed.encoding_offset = encoding.offset;
        parsed.encoding_len = encoding.len;
        if (index == bytes.len) return .{ .parsed = parsed };
        if (!skipRequiredXmlWhitespace(bytes, &index)) return .{ .malformed = index };
        if (index == bytes.len) return .{ .parsed = parsed };
    }

    if (!consumeLiteral(bytes, &index, "standalone")) return .{ .malformed = index };
    if (!consumeEquals(bytes, &index)) return .{ .malformed = index };
    const standalone = consumeQuoted(bytes, &index) orelse return .{ .malformed = index };
    const standalone_bytes = bytes[standalone.offset..][0..standalone.len];
    if (std.mem.eql(u8, standalone_bytes, "yes")) {
        parsed.standalone = true;
    } else if (!std.mem.eql(u8, standalone_bytes, "no")) {
        return .{ .malformed = standalone.offset };
    }
    parsed.standalone_declared = true;
    if (index == bytes.len) return .{ .parsed = parsed };
    if (!skipRequiredXmlWhitespace(bytes, &index) or index != bytes.len) {
        return .{ .malformed = index };
    }
    return .{ .parsed = parsed };
}

fn skipRequiredXmlWhitespace(bytes: []const u8, index: *usize) bool {
    const start = index.*;
    while (index.* < bytes.len and isXmlWhitespace(bytes[index.*])) index.* += 1;
    return index.* != start;
}

fn skipOptionalXmlWhitespace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and isXmlWhitespace(bytes[index.*])) index.* += 1;
}

fn startsWithLiteral(bytes: []const u8, index: usize, literal: []const u8) bool {
    return literal.len <= bytes.len -| index and
        std.mem.eql(u8, bytes[index..][0..literal.len], literal);
}

fn consumeLiteral(bytes: []const u8, index: *usize, literal: []const u8) bool {
    if (!startsWithLiteral(bytes, index.*, literal)) return false;
    index.* += literal.len;
    return true;
}

fn consumeEquals(bytes: []const u8, index: *usize) bool {
    skipOptionalXmlWhitespace(bytes, index);
    if (index.* == bytes.len or bytes[index.*] != '=') return false;
    index.* += 1;
    skipOptionalXmlWhitespace(bytes, index);
    return true;
}

fn consumeQuoted(bytes: []const u8, index: *usize) ?ByteRange {
    if (index.* == bytes.len) return null;
    const quote = bytes[index.*];
    if (quote != '\'' and quote != '"') return null;
    index.* += 1;
    const start = index.*;
    while (index.* < bytes.len and bytes[index.*] != quote) index.* += 1;
    if (index.* == bytes.len) return null;
    const result: ByteRange = .{ .offset = start, .len = index.* - start };
    index.* += 1;
    return result;
}

fn isXml10VersionNumber(bytes: []const u8) bool {
    if (bytes.len < 3 or bytes[0] != '1' or bytes[1] != '.') return false;
    for (bytes[2..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isDottedVersionNumber(bytes: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, bytes, '.') orelse return false;
    if (dot == 0 or dot + 1 == bytes.len) return false;
    for (bytes[0..dot]) |byte| if (!std.ascii.isDigit(byte)) return false;
    for (bytes[dot + 1 ..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isEncodingName(bytes: []const u8) bool {
    if (bytes.len == 0 or !std.ascii.isAlphabetic(bytes[0])) return false;
    for (bytes[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn isAsciiCaseInsensitiveXml(bytes: []const u8) bool {
    return bytes.len == 3 and std.ascii.eqlIgnoreCase(bytes, "xml");
}

fn qnameParts(raw: []const u8) ?QNameParts {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse
        return .{ .prefix = null, .local = raw };
    if (colon == 0 or colon + 1 == raw.len) return null;
    if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':') != null) return null;
    if (!isNcNameStart(raw[colon + 1 ..])) return null;
    return .{
        .prefix = raw[0..colon],
        .local = raw[colon + 1 ..],
    };
}

fn qnameErrorIndex(raw: []const u8) usize {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return 0;
    if (colon == 0) return 0;
    if (colon + 1 == raw.len) return colon;
    if (std.mem.indexOfScalarPos(u8, raw, colon + 1, ':')) |second| return second;
    return if (isNcNameStart(raw[colon + 1 ..])) colon else colon + 1;
}

fn isNcNameStart(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return false;
    if (sequence_len > bytes.len) return false;
    const codepoint = std.unicode.utf8Decode(bytes[0..sequence_len]) catch return false;
    return codepoint != ':' and isXml10NameStart(codepoint);
}

fn namespaceDeclarationPrefix(raw: []const u8, parts: QNameParts) ?[]const u8 {
    if (std.mem.eql(u8, raw, "xmlns")) return "";
    if (parts.prefix) |prefix| {
        if (std.mem.eql(u8, prefix, "xmlns")) return parts.local;
    }
    return null;
}

fn expandedComparisonCost(left: ExpandedName, right: ExpandedName) usize {
    return optionalBytesLength(left.namespace_uri) +|
        optionalBytesLength(right.namespace_uri) +|
        left.local.len +|
        right.local.len +| 2;
}

fn optionalBytesLength(value: ?[]const u8) usize {
    return if (value) |bytes| bytes.len else 0;
}

fn sumSourceAdvances(advances: []const u8) u64 {
    var total: u64 = 0;
    for (advances) |advance| total += advance;
    return total;
}

fn utf16SourceBytes(utf8: []const u8) u64 {
    var total: u64 = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        total += if (codepoint < 0x10000) 2 else 4;
    }
    return total;
}

fn optionalBytesOrder(left: ?[]const u8, right: ?[]const u8) std.math.Order {
    if (left) |left_bytes| {
        if (right) |right_bytes| return std.mem.order(u8, left_bytes, right_bytes);
        return .gt;
    }
    return if (right == null) .eq else .lt;
}

fn expandedNamesEqual(left: ExpandedName, right: ExpandedName) bool {
    return optionalBytesOrder(left.namespace_uri, right.namespace_uri) == .eq and
        std.mem.eql(u8, left.local, right.local);
}

fn failureToError(failure: Failure) ReadError {
    return switch (failure) {
        .invalid_xml => error.InvalidXml,
        .invalid_dtd => error.InvalidDtd,
        .not_valid => error.NotValid,
        .unsupported_feature => error.UnsupportedFeature,
        .limit_exceeded => error.LimitExceeded,
        .out_of_memory => error.OutOfMemory,
        .resolver_failed => error.ResolverFailed,
        .read_failed => error.ReadFailed,
        .cancelled => error.Cancelled,
        .not_normalized => error.NotNormalized,
    };
}

fn validationLocation(
    comptime config: Config,
    source: validation_module.SourceLocation,
) Location(config) {
    var result = locationFromSource(config, source.source_id, source.byte_offset);
    if (config.diagnostic_location == .line_column) {
        result.line = source.line;
        result.byte_column = source.byte_column;
    }
    return result;
}

fn toValidationLocation(
    comptime config: Config,
    location: Location(config),
) validation_module.SourceLocation {
    return .{
        .source_id = location.source_id,
        .byte_offset = location.byte_offset,
        .line = if (config.diagnostic_location == .line_column) location.line else 1,
        .byte_column = if (config.diagnostic_location == .line_column) location.byte_column else 1,
    };
}

const SpaceTokenIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    fn init(bytes: []const u8) SpaceTokenIterator {
        return .{ .bytes = bytes };
    }

    fn next(self: *SpaceTokenIterator) ?[]const u8 {
        while (self.index < self.bytes.len and self.bytes[self.index] == ' ') self.index += 1;
        if (self.index == self.bytes.len) return null;
        const start = self.index;
        while (self.index < self.bytes.len and self.bytes[self.index] != ' ') self.index += 1;
        return self.bytes[start..self.index];
    }
};

fn allXmlWhitespace(bytes: []const u8) bool {
    for (bytes) |byte| if (!isXmlWhitespace(byte)) return false;
    return true;
}

fn validValidationName(comptime config: Config, bytes: []const u8) bool {
    return dtd_module.validName(bytes) and
        (!config.profile.hasNamespaces() or std.mem.indexOfScalar(u8, bytes, ':') == null);
}

fn validityDiagnosticCode(code: validation_module.IssueCode) DiagnosticCode {
    return switch (code) {
        .missing_doctype => .validity_missing_doctype,
        .root_name_mismatch => .validity_root_name_mismatch,
        .undeclared_element => .validity_undeclared_element,
        .duplicate_element_declaration => .validity_duplicate_element_declaration,
        .nondeterministic_content_model => .validity_nondeterministic_content_model,
        .improper_parameter_entity_nesting => .validity_parameter_entity_nesting,
        .duplicate_mixed_content_name => .validity_duplicate_mixed_content_name,
        .invalid_element_content => .validity_element_content,
        .undeclared_attribute => .validity_undeclared_attribute,
        .undeclared_entity => .validity_undeclared_entity,
        .required_attribute_missing => .validity_required_attribute,
        .fixed_attribute_mismatch => .validity_fixed_attribute,
        .invalid_attribute_value => .validity_attribute_value,
        .duplicate_id => .validity_duplicate_id,
        .unresolved_idref => .validity_unresolved_idref,
        .multiple_id_attributes => .validity_multiple_id_attributes,
        .invalid_id_default => .validity_id_default,
        .multiple_notation_attributes => .validity_multiple_notation_attributes,
        .notation_on_empty_element => .validity_notation_on_empty_element,
        .duplicate_enumeration_token => .validity_duplicate_enumeration_token,
        .undeclared_notation => .validity_undeclared_notation,
        .duplicate_notation_declaration => .validity_duplicate_notation,
        .invalid_xml_space_declaration => .validity_xml_space_declaration,
        .standalone_external_default => .validity_standalone_external_default,
        .standalone_external_normalization => .validity_standalone_external_normalization,
        .standalone_external_whitespace => .validity_standalone_external_whitespace,
    };
}

const DecodedExternalSource = struct {
    bytes: []u8,
    source_advances: []u32,
    source_start_offset: u64,
    source_start_line: u64,
    source_start_column: u64,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.source_advances);
    }
};

const ExternalDecodeFailure = struct {
    code: DiagnosticCode,
    byte_offset: u64,
    line: u64,
    byte_column: u64,
};

fn setExternalDecodeFailure(
    failure: *?ExternalDecodeFailure,
    code: DiagnosticCode,
    source_start_offset: usize,
    decoded: []const u8,
    source_advances: ?[]const u32,
    decoded_limit: usize,
    byte_offset: usize,
) void {
    var location: ExternalDecodeFailure = .{
        .code = code,
        .byte_offset = source_start_offset,
        .line = 1,
        .byte_column = 1,
    };
    var cursor: usize = 0;
    while (cursor < @min(decoded_limit, decoded.len)) {
        const byte = decoded[cursor];
        const advance = if (source_advances) |values| values[cursor] else 1;
        location.byte_offset += advance;
        cursor += 1;
        if (byte == '\r') {
            if (cursor < decoded_limit and cursor < decoded.len and decoded[cursor] == '\n') {
                location.byte_offset += if (source_advances) |values| values[cursor] else 1;
                cursor += 1;
            }
            location.line += 1;
            location.byte_column = 1;
        } else if (byte == '\n') {
            location.line += 1;
            location.byte_column = 1;
        } else {
            location.byte_column += advance;
        }
    }
    if (byte_offset > location.byte_offset) {
        location.byte_column += byte_offset - location.byte_offset;
    }
    location.byte_offset = byte_offset;
    failure.* = location;
}

fn decodeExternalSource(
    allocator: std.mem.Allocator,
    raw: []const u8,
    hint: ?SourceEncoding,
    transcoder: ?encoding_module.Transcoder,
    version: XmlVersion,
    max_bytes: usize,
    failure: *?ExternalDecodeFailure,
) dtd_module.ParseError!DecodedExternalSource {
    var encoding = hint orelse .utf8;
    var start: usize = 0;
    if (transcoder != null or hint == .other) {
        encoding = .other;
    } else if (raw.len >= 3 and std.mem.eql(u8, raw[0..3], "\xef\xbb\xbf")) {
        if (hint != null and hint.? != .utf8) {
            setExternalDecodeFailure(failure, .encoding_mismatch, 0, &.{}, null, 0, 0);
            return error.InvalidDtd;
        }
        encoding = .utf8;
        start = 3;
    } else if (raw.len >= 2 and std.mem.eql(u8, raw[0..2], "\xfe\xff")) {
        if (hint != null and hint.? != .utf16_be) {
            setExternalDecodeFailure(failure, .encoding_mismatch, 0, &.{}, null, 0, 0);
            return error.InvalidDtd;
        }
        encoding = .utf16_be;
        start = 2;
    } else if (raw.len >= 2 and std.mem.eql(u8, raw[0..2], "\xff\xfe")) {
        if (hint != null and hint.? != .utf16_le) {
            setExternalDecodeFailure(failure, .encoding_mismatch, 0, &.{}, null, 0, 0);
            return error.InvalidDtd;
        }
        encoding = .utf16_le;
        start = 2;
    } else if (hint == null and raw.len >= 4 and std.mem.eql(u8, raw[0..4], "\x00\x3c\x00\x3f")) {
        encoding = .utf16_be;
    } else if (hint == null and raw.len >= 4 and std.mem.eql(u8, raw[0..4], "\x3c\x00\x3f\x00")) {
        encoding = .utf16_le;
    }
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var advances: std.ArrayList(u32) = .empty;
    defer advances.deinit(allocator);
    switch (encoding) {
        .utf8 => {
            const bytes = raw[start..];
            var cursor: usize = 0;
            while (cursor < bytes.len) switch (probeUtf8(bytes[cursor..])) {
                .scalar => |scalar| cursor += scalar.len,
                .incomplete => {
                    setExternalDecodeFailure(
                        failure,
                        .malformed_encoding,
                        start,
                        bytes,
                        null,
                        cursor,
                        start + cursor,
                    );
                    return error.InvalidDtd;
                },
                .invalid => |index| {
                    setExternalDecodeFailure(
                        failure,
                        .malformed_encoding,
                        start,
                        bytes,
                        null,
                        cursor,
                        start + cursor + index,
                    );
                    return error.InvalidDtd;
                },
            };
            decoded.appendSlice(allocator, bytes) catch return error.OutOfMemory;
            advances.appendNTimes(allocator, 1, bytes.len) catch return error.OutOfMemory;
        },
        .utf16_le, .utf16_be => {
            if ((raw.len - start) % 2 != 0) {
                setExternalDecodeFailure(
                    failure,
                    .malformed_encoding,
                    start,
                    decoded.items,
                    advances.items,
                    decoded.items.len,
                    raw.len - 1,
                );
                return error.InvalidDtd;
            }
            var cursor = start;
            while (cursor < raw.len) {
                const first_offset = cursor;
                const first = readUtf16Unit(raw[cursor..][0..2], encoding == .utf16_le);
                cursor += 2;
                var scalar: u21 = undefined;
                if (first >= 0xd800 and first <= 0xdbff) {
                    if (cursor == raw.len) {
                        setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, first_offset);
                        return error.InvalidDtd;
                    }
                    const second = readUtf16Unit(raw[cursor..][0..2], encoding == .utf16_le);
                    if (second < 0xdc00 or second > 0xdfff) {
                        setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, cursor);
                        return error.InvalidDtd;
                    }
                    cursor += 2;
                    scalar = @intCast(0x10000 +
                        ((@as(u32, first) - 0xd800) << 10) +
                        (@as(u32, second) - 0xdc00));
                } else {
                    if (first >= 0xdc00 and first <= 0xdfff) {
                        setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, first_offset);
                        return error.InvalidDtd;
                    }
                    scalar = @intCast(first);
                }
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(scalar, &bytes) catch unreachable;
                if (len > max_bytes -| decoded.items.len) {
                    setExternalDecodeFailure(failure, .external_resource_bytes_limit, start, decoded.items, advances.items, decoded.items.len, first_offset);
                    return error.LimitExceeded;
                }
                decoded.appendSlice(allocator, bytes[0..len]) catch return error.OutOfMemory;
                advances.appendNTimes(allocator, 0, len) catch return error.OutOfMemory;
                advances.items[advances.items.len - 1] = if (scalar < 0x10000) 2 else 4;
            }
        },
        .other => {
            const converter = transcoder orelse {
                setExternalDecodeFailure(failure, .unsupported_encoding, start, &.{}, null, 0, start);
                return error.UnsupportedFeature;
            };
            var cursor = start;
            var output: [4096]u8 = undefined;
            var output_advances: [4096]u8 = undefined;
            decode: while (true) {
                const remaining = raw[cursor..];
                const bounded = remaining[0..@min(remaining.len, std.math.maxInt(u8))];
                const final = bounded.len == remaining.len;
                const step = converter.run(
                    bounded,
                    final,
                    &output,
                    &output_advances,
                ) catch {
                    setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, cursor);
                    return error.InvalidDtd;
                };
                switch (step) {
                    .progress => |progress| {
                        if (progress.produced > max_bytes -| decoded.items.len) {
                            setExternalDecodeFailure(failure, .external_resource_bytes_limit, start, decoded.items, advances.items, decoded.items.len, cursor);
                            return error.LimitExceeded;
                        }
                        decoded.appendSlice(allocator, output[0..progress.produced]) catch
                            return error.OutOfMemory;
                        cursor += progress.consumed;
                        for (output_advances[0..progress.produced]) |advance| {
                            advances.append(allocator, advance) catch return error.OutOfMemory;
                        }
                    },
                    .need_input => {
                        if (final and bounded.len == 0) break :decode;
                        setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, cursor);
                        return error.InvalidDtd;
                    },
                    .need_output => {
                        setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, cursor);
                        return error.InvalidDtd;
                    },
                    .malformed => |offset| {
                        setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, cursor + offset);
                        return error.InvalidDtd;
                    },
                    .unsupported => {
                        setExternalDecodeFailure(failure, .unsupported_encoding, start, decoded.items, advances.items, decoded.items.len, cursor);
                        return error.UnsupportedFeature;
                    },
                    .cancelled => {
                        setExternalDecodeFailure(failure, .transcoder_cancelled, start, decoded.items, advances.items, decoded.items.len, cursor);
                        return error.Cancelled;
                    },
                }
            }
            _ = std.unicode.Utf8View.init(decoded.items) catch {
                setExternalDecodeFailure(failure, .malformed_encoding, start, decoded.items, advances.items, decoded.items.len, cursor);
                return error.InvalidDtd;
            };
        },
    }

    var content = decoded.items;
    var content_advances = advances.items;
    var source_start_offset: u64 = start;
    var source_start_line: u64 = 1;
    var source_start_column: u64 = 1;
    if (externalTextDeclaration(content)) |declaration| {
        if (version == .xml10 and declaration.version == .xml11) {
            setExternalDecodeFailure(
                failure,
                .unsupported_version,
                start,
                content,
                content_advances,
                0,
                start,
            );
            return error.InvalidDtd;
        }
        if (!externalEncodingMatches(encoding, declaration.encoding)) {
            const encoding_offset = @intFromPtr(declaration.encoding.ptr) - @intFromPtr(content.ptr);
            var raw_offset = start;
            for (content_advances[0..encoding_offset]) |advance| raw_offset += advance;
            setExternalDecodeFailure(
                failure,
                .encoding_mismatch,
                start,
                content,
                content_advances,
                encoding_offset,
                raw_offset,
            );
            return error.InvalidDtd;
        }
        var declaration_cursor: usize = 0;
        while (declaration_cursor < declaration.end) {
            const byte = content[declaration_cursor];
            var source_advance = content_advances[declaration_cursor];
            source_start_offset += source_advance;
            declaration_cursor += 1;
            if (byte == '\r') {
                if (declaration_cursor < declaration.end and content[declaration_cursor] == '\n') {
                    source_advance = content_advances[declaration_cursor];
                    source_start_offset += source_advance;
                    declaration_cursor += 1;
                }
                source_start_line += 1;
                source_start_column = 1;
            } else {
                source_start_column += source_advance;
            }
        }
        content = content[declaration.end..];
        content_advances = content_advances[declaration.end..];
    } else if (malformedExternalTextDeclaration(content)) {
        setExternalDecodeFailure(failure, .malformed_declaration, start, content, content_advances, 0, start);
        return error.InvalidDtd;
    }

    var validation_cursor: usize = 0;
    while (validation_cursor < content.len) {
        const scalar = switch (probeUtf8(content[validation_cursor..])) {
            .scalar => |value| value,
            .incomplete, .invalid => unreachable,
        };
        if (!isXmlLiteralChar(scalar.codepoint, version)) {
            var raw_offset: usize = @intCast(source_start_offset);
            for (content_advances[0..validation_cursor]) |advance| raw_offset += advance;
            setExternalDecodeFailure(
                failure,
                .forbidden_character,
                @intCast(source_start_offset),
                content,
                content_advances,
                validation_cursor,
                raw_offset,
            );
            return error.InvalidDtd;
        }
        validation_cursor += scalar.len;
    }
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var normalized_advances: std.ArrayList(u32) = .empty;
    errdefer normalized_advances.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < content.len) {
        if (content[cursor] == '\r') {
            normalized.append(allocator, '\n') catch return error.OutOfMemory;
            var source_advance = content_advances[cursor];
            cursor += 1;
            if (cursor < content.len and content[cursor] == '\n') {
                source_advance += content_advances[cursor];
                cursor += 1;
            } else if (version == .xml11 and
                std.mem.startsWith(u8, content[cursor..], "\xc2\x85"))
            {
                source_advance += content_advances[cursor] + content_advances[cursor + 1];
                cursor += 2;
            }
            normalized_advances.append(allocator, source_advance) catch return error.OutOfMemory;
        } else if (version == .xml11 and
            (std.mem.startsWith(u8, content[cursor..], "\xc2\x85") or
                std.mem.startsWith(u8, content[cursor..], "\xe2\x80\xa8")))
        {
            const line_len: usize = if (content[cursor] == 0xc2) 2 else 3;
            normalized.append(allocator, '\n') catch return error.OutOfMemory;
            var source_advance: u32 = 0;
            for (content_advances[cursor..][0..line_len]) |advance| source_advance += advance;
            normalized_advances.append(allocator, source_advance) catch return error.OutOfMemory;
            cursor += line_len;
        } else {
            normalized.append(allocator, content[cursor]) catch return error.OutOfMemory;
            normalized_advances.append(allocator, content_advances[cursor]) catch
                return error.OutOfMemory;
            cursor += 1;
        }
    }
    const owned_bytes = normalized.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(owned_bytes);
    const owned_advances = normalized_advances.toOwnedSlice(allocator) catch
        return error.OutOfMemory;
    return .{
        .bytes = owned_bytes,
        .source_advances = owned_advances,
        .source_start_offset = source_start_offset,
        .source_start_line = source_start_line,
        .source_start_column = source_start_column,
    };
}

fn readUtf16Unit(bytes: *const [2]u8, little_endian: bool) u16 {
    return if (little_endian)
        @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8)
    else
        (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

const ExternalTextDeclaration = struct {
    end: usize,
    encoding: []const u8,
    version: ?XmlVersion,
};

fn externalTextDeclaration(bytes: []const u8) ?ExternalTextDeclaration {
    if (!std.mem.startsWith(u8, bytes, "<?xml") or bytes.len == 5 or
        !isXmlWhitespace(bytes[5])) return null;
    const close = std.mem.indexOfPos(u8, bytes, 6, "?>") orelse return null;
    const declaration = bytes[5..close];
    if (hasNonAscii(declaration)) return null;
    var cursor: usize = 0;
    if (!skipRequiredXmlWhitespace(declaration, &cursor)) return null;
    const version = if (startsWithLiteral(declaration, cursor, "version")) blk: {
        _ = consumeLiteral(declaration, &cursor, "version");
        if (!consumeEquals(declaration, &cursor)) return null;
        const range = consumeQuoted(declaration, &cursor) orelse return null;
        const value = declaration[range.offset..][0..range.len];
        if (std.mem.eql(u8, value, "1.0")) break :blk XmlVersion.xml10;
        if (std.mem.eql(u8, value, "1.1")) break :blk XmlVersion.xml11;
        return null;
    } else null;
    if (version != null and !skipRequiredXmlWhitespace(declaration, &cursor)) return null;
    if (!consumeLiteral(declaration, &cursor, "encoding")) return null;
    if (!consumeEquals(declaration, &cursor)) return null;
    const encoding_range = consumeQuoted(declaration, &cursor) orelse return null;
    const encoding = declaration[encoding_range.offset..][0..encoding_range.len];
    if (!isEncodingName(encoding)) return null;
    skipOptionalXmlWhitespace(declaration, &cursor);
    if (cursor != declaration.len) return null;
    return .{ .end = close + 2, .encoding = encoding, .version = version };
}

fn malformedExternalTextDeclaration(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "<?xml") and bytes.len > 5 and
        isXmlWhitespace(bytes[5]) and std.mem.indexOfPos(u8, bytes, 6, "?>") != null and
        externalTextDeclaration(bytes) == null;
}

fn externalEncodingMatches(encoding: SourceEncoding, declared: []const u8) bool {
    return switch (encoding) {
        .utf8 => std.ascii.eqlIgnoreCase(declared, "UTF-8"),
        .utf16_le, .utf16_be => std.ascii.eqlIgnoreCase(declared, "UTF-16") or
            std.ascii.eqlIgnoreCase(declared, if (encoding == .utf16_le) "UTF-16LE" else "UTF-16BE"),
        .other => true,
    };
}

fn externalRawStartReady(
    raw: []const u8,
    hint: ?SourceEncoding,
    max_declaration_bytes: usize,
) bool {
    var encoding = hint orelse .utf8;
    var start: usize = 0;
    if (raw.len >= 3 and std.mem.eql(u8, raw[0..3], "\xef\xbb\xbf")) {
        encoding = .utf8;
        start = 3;
    } else if (raw.len >= 2 and std.mem.eql(u8, raw[0..2], "\xfe\xff")) {
        encoding = .utf16_be;
        start = 2;
    } else if (raw.len >= 2 and std.mem.eql(u8, raw[0..2], "\xff\xfe")) {
        encoding = .utf16_le;
        start = 2;
    } else if (hint == null and raw.len >= 4 and std.mem.eql(u8, raw[0..4], "\x00\x3c\x00\x3f")) {
        encoding = .utf16_be;
    } else if (hint == null and raw.len >= 4 and std.mem.eql(u8, raw[0..4], "\x3c\x00\x3f\x00")) {
        encoding = .utf16_le;
    } else if (raw.len < 4 and hint == null) {
        return false;
    }
    if (encoding == .other) return true;
    const width: usize = if (encoding == .utf8) 1 else 2;
    if (raw.len < start + 6 * width) return false;
    const prefix = "<?xml";
    for (prefix, 0..) |expected, index| {
        const actual = externalAsciiByte(raw, start + index * width, encoding) orelse return true;
        if (actual != expected) return true;
    }
    const sixth = externalAsciiByte(raw, start + 5 * width, encoding) orelse return true;
    if (!isXmlWhitespace(sixth)) return true;
    var cursor = start + 6 * width;
    while (cursor + 2 * width <= raw.len) : (cursor += width) {
        if (externalAsciiByte(raw, cursor, encoding) == '?' and
            externalAsciiByte(raw, cursor + width, encoding) == '>') return true;
    }
    return raw.len >= start + max_declaration_bytes * width;
}

const DetectedExternalEncoding = struct {
    encoding: SourceEncoding,
    signature_len: usize = 0,
};

fn detectExternalRawEncoding(raw: []const u8, hint: ?SourceEncoding) ?DetectedExternalEncoding {
    var detected: DetectedExternalEncoding = .{ .encoding = hint orelse .utf8 };
    if (raw.len >= 3 and std.mem.eql(u8, raw[0..3], "\xef\xbb\xbf")) {
        detected = .{ .encoding = .utf8, .signature_len = 3 };
    } else if (raw.len >= 2 and std.mem.eql(u8, raw[0..2], "\xfe\xff")) {
        detected = .{ .encoding = .utf16_be, .signature_len = 2 };
    } else if (raw.len >= 2 and std.mem.eql(u8, raw[0..2], "\xff\xfe")) {
        detected = .{ .encoding = .utf16_le, .signature_len = 2 };
    } else if (raw.len >= 4 and std.mem.eql(u8, raw[0..4], "\x00\x3c\x00\x3f")) {
        detected.encoding = .utf16_be;
    } else if (raw.len >= 4 and std.mem.eql(u8, raw[0..4], "\x3c\x00\x3f\x00")) {
        detected.encoding = .utf16_le;
    }
    if (hint) |expected| {
        if (expected != .other and expected != detected.encoding) return null;
    }
    return detected;
}

fn externalAsciiByte(raw: []const u8, offset: usize, encoding: SourceEncoding) ?u8 {
    return switch (encoding) {
        .utf8 => raw[offset],
        .utf16_le => if (raw[offset + 1] == 0) raw[offset] else null,
        .utf16_be => if (raw[offset] == 0) raw[offset + 1] else null,
        .other => null,
    };
}

const normal_raw_config: Config = .{
    .profile = .xml11_nonvalidating,
    .event_locations = true,
    .external_sources = true,
};

const normal_raw_no_dtd_config: Config = .{
    .profile = .xml11_no_dtd,
    .event_locations = true,
};

const normal_namespace_config: Config = .{
    .profile = .xml11_ns_nonvalidating,
    .event_locations = true,
    .external_sources = true,
};

const normal_namespace_no_dtd_config: Config = .{
    .profile = .xml11_ns_no_dtd,
    .event_locations = true,
};

const normal_raw_validating_config: Config = .{
    .profile = .xml11_dtd_validating,
    .event_locations = true,
    .external_sources = true,
};

const normal_namespace_validating_config: Config = .{
    .profile = .xml11_ns_dtd_validating,
    .event_locations = true,
    .external_sources = true,
};

const NormalEngine = union(enum) {
    raw_no_dtd: Reader(normal_raw_no_dtd_config),
    namespaces_no_dtd: Reader(normal_namespace_no_dtd_config),
    raw: Reader(normal_raw_config),
    namespaces: Reader(normal_namespace_config),
    raw_validating: Reader(normal_raw_validating_config),
    namespaces_validating: Reader(normal_namespace_validating_config),
};

const NormalDiagnosticCore = struct {
    code: DiagnosticCode,
    primary: NormalLocation,
    related: ?NormalLocation,
};

const NormalDtdFindingCore = struct {
    code: DiagnosticCode,
    primary: NormalLocation,
    related: ?NormalLocation,
};

const NormalDtdCancelTrace = enum {
    none,
    first_finding,
    later_finding,
};

/// Normal reader with runtime namespace and DTD policy selection.
pub const NormalReader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    options: NormalReaderOptions,
    source: NormalSource,
    engine: NormalEngine,
    source_started: bool = false,
    source_finished: bool = false,
    pending_toss: usize = 0,
    source_tossed: u64 = 0,
    complete: bool = false,
    deinitialized: bool = false,
    in_call: bool = false,
    failure: ?NormalReadError = null,
    first_diagnostic: ?NormalDiagnosticCore = null,
    diagnostic_inclusions: std.ArrayList(NormalLocation) = .empty,
    first_dtd_finding: ?NormalDtdFindingCore = null,
    dtd_finding_inclusions: std.ArrayList(NormalLocation) = .empty,
    dtd_callback_inclusions: std.ArrayList(NormalLocation) = .empty,
    dtd_finding_copy_failed: bool = false,
    dtd_cancel_trace: NormalDtdCancelTrace = .none,
    event_attributes: std.ArrayList(NormalAttribute) = .empty,
    event_namespace_declarations: std.ArrayList(NormalNamespaceDeclaration) = .empty,
    effective_version: XmlVersion = .xml10,
    external_content_skipped: bool = false,
    pending_event: ?NormalEvent = null,
    text_run_source_id: ?u32 = null,
    text_run_end: u64 = 0,
    text_run_origin: TextOrigin = .character_data,

    /// Initializes the normal reader without reading or allocating.
    pub fn init(
        allocator: std.mem.Allocator,
        source: NormalSource,
        options: NormalReaderOptions,
    ) NormalInitError!Self {
        if (!validNormalOptions(options)) return error.InvalidOptions;
        return .{
            .allocator = allocator,
            .options = options,
            .source = source,
            .engine = try initNormalEngine(allocator, options),
        };
    }

    /// Releases parser-owned memory. The caller retains the root source.
    pub fn deinit(self: *Self) void {
        std.debug.assert(!self.deinitialized);
        std.debug.assert(!self.in_call);
        self.in_call = true;
        switch (self.engine) {
            inline else => |*parser| parser.deinit(),
        }
        self.diagnostic_inclusions.deinit(self.allocator);
        self.dtd_finding_inclusions.deinit(self.allocator);
        self.dtd_callback_inclusions.deinit(self.allocator);
        self.event_attributes.deinit(self.allocator);
        self.event_namespace_declarations.deinit(self.allocator);
        self.deinitialized = true;
        self.in_call = false;
    }

    /// Replaces the source and options without reading or allocating.
    pub fn reset(
        self: *Self,
        source: NormalSource,
        options: NormalReaderOptions,
        mode: ResetMode,
    ) NormalResetError!void {
        if (self.deinitialized or self.in_call) return error.InvalidState;
        if (!validNormalOptions(options)) return error.InvalidOptions;

        self.in_call = true;
        defer self.in_call = false;

        const retain_facade_capacity = mode == .retain_capacity and
            self.memoryUsage().retained_capacity <= options.limits.max_retained_bytes;
        const retain_engine_capacity = retain_facade_capacity and
            !normalOptionsDisableStorage(self.options, options);
        const engine_mode: ResetMode = if (retain_engine_capacity)
            .retain_capacity
        else
            .release_memory;
        const selected = normalEngineKind(options);
        if (std.meta.activeTag(self.engine) == selected) {
            switch (self.engine) {
                .raw_no_dtd => |*parser| resetNormalParser(
                    normal_raw_no_dtd_config,
                    parser,
                    options,
                    engine_mode,
                ),
                .namespaces_no_dtd => |*parser| resetNormalParser(
                    normal_namespace_no_dtd_config,
                    parser,
                    options,
                    engine_mode,
                ),
                .raw => |*parser| resetNormalParser(
                    normal_raw_config,
                    parser,
                    options,
                    engine_mode,
                ),
                .namespaces => |*parser| resetNormalParser(
                    normal_namespace_config,
                    parser,
                    options,
                    engine_mode,
                ),
                .raw_validating => |*parser| resetNormalParser(
                    normal_raw_validating_config,
                    parser,
                    options,
                    engine_mode,
                ),
                .namespaces_validating => |*parser| resetNormalParser(
                    normal_namespace_validating_config,
                    parser,
                    options,
                    engine_mode,
                ),
            }
        } else {
            const replacement = initNormalEngine(self.allocator, options) catch
                return error.InvalidOptions;
            switch (self.engine) {
                inline else => |*parser| parser.deinit(),
            }
            self.engine = replacement;
        }

        if (!retain_facade_capacity) {
            self.releaseFacadeStorage();
        } else {
            if (normalOptionsUseExternalStorage(options)) {
                self.diagnostic_inclusions.clearRetainingCapacity();
            } else {
                self.diagnostic_inclusions.deinit(self.allocator);
                self.diagnostic_inclusions = .empty;
            }
            if (normalOptionsUseValidationStorage(options)) {
                self.dtd_finding_inclusions.clearRetainingCapacity();
                self.dtd_callback_inclusions.clearRetainingCapacity();
            } else {
                self.dtd_finding_inclusions.deinit(self.allocator);
                self.dtd_callback_inclusions.deinit(self.allocator);
                self.dtd_finding_inclusions = .empty;
                self.dtd_callback_inclusions = .empty;
            }
            self.event_attributes.clearRetainingCapacity();
            if (options.namespaces == .raw) {
                self.event_namespace_declarations.deinit(self.allocator);
                self.event_namespace_declarations = .empty;
            } else {
                self.event_namespace_declarations.clearRetainingCapacity();
            }
        }
        self.options = options;
        self.source = source;
        self.source_started = false;
        self.source_finished = false;
        self.pending_toss = 0;
        self.source_tossed = 0;
        self.complete = false;
        self.failure = null;
        self.first_diagnostic = null;
        self.first_dtd_finding = null;
        self.dtd_finding_copy_failed = false;
        self.dtd_cancel_trace = .none;
        self.effective_version = .xml10;
        self.external_content_skipped = false;
        self.pending_event = null;
        self.text_run_source_id = null;
        self.text_run_end = 0;
        self.text_run_origin = .character_data;
    }

    /// Produces the next stable event or returns null after the document ends.
    pub fn next(self: *Self) NormalReadError!?NormalEvent {
        if (self.deinitialized) return error.InvalidState;
        if (self.in_call) return error.InvalidState;
        if (self.failure) |failure| return failure;
        if (self.complete) return null;

        self.in_call = true;
        defer self.in_call = false;

        // A queued start event still borrows the facade arrays filled during conversion.
        if (self.pending_event) |event| {
            self.pending_event = null;
            if (event.span.source_id == 0) self.commitRootStreamBytes(event.span.end);
            return event;
        }

        self.event_attributes.clearRetainingCapacity();
        self.event_namespace_declarations.clearRetainingCapacity();

        return switch (self.engine) {
            .raw_no_dtd => |*parser| self.nextFrom(normal_raw_no_dtd_config, parser),
            .namespaces_no_dtd => |*parser| self.nextFrom(
                normal_namespace_no_dtd_config,
                parser,
            ),
            .raw => |*parser| self.nextFrom(normal_raw_config, parser),
            .namespaces => |*parser| self.nextFrom(normal_namespace_config, parser),
            .raw_validating => |*parser| self.nextFrom(normal_raw_validating_config, parser),
            .namespaces_validating => |*parser| self.nextFrom(
                normal_namespace_validating_config,
                parser,
            ),
        };
    }

    /// Returns the first fatal diagnostic, if one exists.
    pub fn diagnostic(self: *const Self) ?NormalDiagnostic {
        const value = self.first_diagnostic orelse return null;
        const inclusions = if (value.code == .dtd_finding_cancelled)
            switch (self.dtd_cancel_trace) {
                .none => self.diagnostic_inclusions.items,
                .first_finding => self.dtd_finding_inclusions.items,
                .later_finding => self.dtd_callback_inclusions.items,
            }
        else
            self.diagnostic_inclusions.items;
        return .{
            .code = value.code,
            .primary = value.primary,
            .related = value.related,
            .inclusion_trace = inclusions,
        };
    }

    /// Returns the first DTD validity finding, retained until reset or deinitialization.
    pub fn firstDtdFinding(self: *const Self) ?NormalDtdFinding {
        const value = self.first_dtd_finding orelse return null;
        return .{
            .code = value.code,
            .primary = value.primary,
            .related = value.related,
            .inclusion_trace = self.dtd_finding_inclusions.items,
        };
    }

    /// Reports memory owned by the selected parser and event conversion storage.
    pub fn memoryUsage(self: *const Self) MemoryUsage {
        var usage = switch (self.engine) {
            inline else => |*parser| parser.memoryUsage(),
        };
        const attribute_capacity = self.event_attributes.capacity *| @sizeOf(NormalAttribute);
        const namespace_capacity = self.event_namespace_declarations.capacity *|
            @sizeOf(NormalNamespaceDeclaration);
        const diagnostic_capacity = self.diagnostic_inclusions.capacity *| @sizeOf(NormalLocation);
        const finding_capacity = (self.dtd_finding_inclusions.capacity +|
            self.dtd_callback_inclusions.capacity) *| @sizeOf(NormalLocation);
        usage.attribute_event_capacity +|= self.event_attributes.capacity;
        usage.namespace_capacity +|= namespace_capacity;
        usage.validation_capacity +|= finding_capacity;
        usage.retained_capacity +|= attribute_capacity +| namespace_capacity +|
            diagnostic_capacity +| finding_capacity;
        return usage;
    }

    /// Returns the first XML 1.1 normalization finding, if one exists.
    pub fn normalizationFinding(self: *const Self) ?NormalNormalizationFinding {
        return switch (self.engine) {
            inline else => |*parser| finding: {
                const result = parser.normalizationResult();
                if (@hasField(@TypeOf(result), "issue")) {
                    const issue = result.issue orelse break :finding null;
                    break :finding .{
                        .kind = issue.kind,
                        .location = normalLocation(
                            self.options.track_lines,
                            issue.location,
                        ),
                    };
                }
                break :finding null;
            },
        };
    }

    fn nextFrom(
        self: *Self,
        comptime config: Config,
        parser: *Reader(config),
    ) NormalReadError!?NormalEvent {
        while (true) {
            if (comptime config.profile.dtdMode() == .validating) {
                parser.options.validation.sink = .{
                    .context = self,
                    .reportFn = normalValidityReporter(config),
                };
            }
            if (parser.lifecycle == .ready or parser.lifecycle == .needs_input) {
                self.refill(config, parser) catch |failure| {
                    return self.recordInternalFailure(config, parser, failure);
                };
            }

            const step = parser.next() catch |failure| {
                return self.recordInternalFailure(config, parser, failure);
            };
            switch (step) {
                .need_input => continue,
                .done => {
                    self.complete = true;
                    return null;
                },
                .event => |event| {
                    const converted = self.convertEvent(config, event) catch |failure| {
                        parser.closeExternalSources();
                        if (self.failure == null) self.recordGeneratedFailure(
                            failure,
                            .out_of_memory,
                            normalLocation(self.options.track_lines, event.span.start),
                        );
                        return failure;
                    };
                    if (converted) |value| {
                        const result = self.finishTextRunBefore(value);
                        if (result.span.source_id == 0) {
                            self.commitRootStreamBytes(result.span.end);
                        }
                        return result;
                    }
                },
            }
        }
    }

    fn refill(
        self: *Self,
        comptime config: Config,
        parser: *Reader(config),
    ) ReadError!void {
        switch (self.source) {
            .slice => |input| {
                if (self.source_started) return error.InvalidState;
                self.source_started = true;
                parser.feed(input, true) catch return error.InvalidState;
            },
            .stream => |input| {
                if (self.options.transcoder != null) {
                    if (self.source_finished) return error.InvalidState;
                    const bytes = input.peekGreedy(1) catch |read_error| switch (read_error) {
                        error.EndOfStream => {
                            self.source_finished = true;
                            return AdapterAccess(config).feedTranscodedRoot(parser, "", true);
                        },
                        error.ReadFailed => return AdapterAccess(config).recordReadFailure(parser),
                    };
                    const pending = AdapterAccess(config).transcoderPendingInput(parser);
                    std.debug.assert(pending < transcoder_input_capacity);
                    const len = @min(bytes.len, transcoder_input_capacity - pending);
                    try AdapterAccess(config).feedTranscodedRoot(parser, bytes[0..len], false);
                    input.toss(len);
                    self.source_tossed += @intCast(len);
                    self.source_started = true;
                    return;
                }
                if (self.pending_toss != 0) {
                    input.toss(self.pending_toss);
                    self.source_tossed += @intCast(self.pending_toss);
                    self.pending_toss = 0;
                }
                if (self.source_finished) return error.InvalidState;
                const bytes = input.peekGreedy(1) catch |read_error| switch (read_error) {
                    error.EndOfStream => {
                        self.source_finished = true;
                        parser.feed("", true) catch return error.InvalidState;
                        return;
                    },
                    error.ReadFailed => return AdapterAccess(config).recordReadFailure(parser),
                };
                self.source_started = true;
                parser.feed(bytes, false) catch return error.InvalidState;
                self.pending_toss = bytes.len;
            },
        }
    }

    fn convertEvent(
        self: *Self,
        comptime config: Config,
        event: Event(config),
    ) NormalReadError!?NormalEvent {
        const span = normalSpan(config, event.span);
        const payload = event.payload;
        if (comptime config.profile.dtdMode() == .rejected) {
            return self.convertCommonEvent(config, span, payload);
        }
        return switch (payload) {
            .document_type => |document_type| .{
                .span = span,
                .data = .{ .document_type = .{
                    .root_name = document_type.root_name,
                    .public_id = document_type.public_id,
                    .system_id = document_type.system_id,
                } },
            },
            .notation_declaration, .unparsed_entity_declaration => null,
            .skipped_entity => |value| result: {
                if (self.options.external == .forbid) {
                    self.recordGeneratedFailure(
                        error.ExternalResourceForbidden,
                        .external_resource_forbidden,
                        normalLocation(self.options.track_lines, event.span.start),
                    );
                    return error.ExternalResourceForbidden;
                }
                self.external_content_skipped = true;
                break :result .{ .span = span, .data = .{ .skipped_external_source = .{
                    .kind = switch (value.kind) {
                        .external_subset => .external_subset,
                        .parameter_entity => .parameter_entity,
                        .general_entity => .general_entity,
                    },
                    .name = value.name,
                    .public_id = value.public_id,
                    .system_id = value.system_id,
                } } };
            },
            .document_start => |value| self.convertCommonEvent(
                config,
                span,
                .{ .document_start = value },
            ),
            .start_element => |value| self.convertCommonEvent(
                config,
                span,
                .{ .start_element = value },
            ),
            .end_element => |value| self.convertCommonEvent(
                config,
                span,
                .{ .end_element = value },
            ),
            .text => |value| self.convertCommonEvent(config, span, .{ .text = value }),
            .comment => |value| self.convertCommonEvent(config, span, .{ .comment = value }),
            .processing_instruction => |value| self.convertCommonEvent(
                config,
                span,
                .{ .processing_instruction = value },
            ),
            .document_end => |value| self.convertCommonEvent(
                config,
                span,
                .{ .document_end = value },
            ),
        };
    }

    fn convertCommonEvent(
        self: *Self,
        comptime config: Config,
        span: NormalSourceSpan,
        payload: NoDtdEventPayload(config),
    ) NormalReadError!?NormalEvent {
        return switch (payload) {
            .document_start => |document| result: {
                self.effective_version = document.effective_version;
                break :result .{ .span = span, .data = .{ .document_start = .{
                    .effective_version = document.effective_version,
                    .source_encoding = document.source_encoding,
                    .declaration = if (document.declared_version) |version| .{
                        .version = if (std.mem.eql(u8, version, "1.1")) .xml11 else .xml10,
                        .encoding = document.declared_encoding,
                        .standalone = if (document.standalone_declared)
                            document.standalone
                        else
                            null,
                    } else null,
                } } };
            },
            .start_element => |element| result: {
                try self.copyAttributes(config, element.attributes);
                if (comptime config.profile.hasNamespaces()) {
                    try self.copyNamespaceDeclarations(element.namespace_declarations);
                }
                break :result .{ .span = span, .data = .{ .start_element = .{
                    .name = normalName(config, element.name),
                    .attributes = self.event_attributes.items,
                    .namespace_declarations = self.event_namespace_declarations.items,
                    .empty_syntax = element.empty_element_syntax,
                } } };
            },
            .end_element => |element| .{
                .span = span,
                .data = .{ .end_element = .{ .name = normalName(config, element.name) } },
            },
            .text => |value| .{
                .span = span,
                .data = .{ .text = .{
                    .bytes = value.bytes,
                    .origin = value.origin,
                    .final_fragment = false,
                } },
            },
            .comment => |value| .{
                .span = span,
                .data = .{ .comment = .{
                    .bytes = value.bytes,
                    .final_fragment = value.complete,
                } },
            },
            .processing_instruction => |value| .{
                .span = span,
                .data = .{ .processing_instruction = .{
                    .target = value.target,
                    .data = value.data,
                    .final_fragment = value.complete,
                } },
            },
            .document_end => |value| .{
                .span = span,
                .data = .{ .document_end = self.normalDocumentEnd(config, value) },
            },
        };
    }

    fn finishTextRunBefore(self: *Self, event: NormalEvent) NormalEvent {
        switch (event.data) {
            .text => |text| {
                self.text_run_source_id = event.span.source_id;
                self.text_run_end = event.span.end;
                self.text_run_origin = text.origin;
                return event;
            },
            else => {
                const source_id = self.text_run_source_id orelse return event;
                const end = if (source_id == event.span.source_id)
                    event.span.start
                else
                    self.text_run_end;
                self.pending_event = event;
                self.text_run_source_id = null;
                return .{
                    .span = .{ .source_id = source_id, .start = end, .end = end },
                    .data = .{ .text = .{
                        .bytes = "",
                        .origin = self.text_run_origin,
                        .final_fragment = true,
                    } },
                };
            },
        }
    }

    fn copyAttributes(
        self: *Self,
        comptime config: Config,
        attributes: []const Attribute(config),
    ) NormalReadError!void {
        self.event_attributes.ensureTotalCapacity(self.allocator, attributes.len) catch
            return error.OutOfMemory;
        for (attributes) |attribute| {
            self.event_attributes.appendAssumeCapacity(.{
                .name = normalName(config, attribute.name),
                .value = attribute.value,
                .span = null,
                .specified = if (@hasField(@TypeOf(attribute), "specified"))
                    attribute.specified
                else
                    true,
                .declared_type = if (@hasField(@TypeOf(attribute), "declared_type"))
                    attribute.declared_type
                else
                    null,
            });
        }
    }

    fn copyNamespaceDeclarations(
        self: *Self,
        declarations: []const NamespaceDeclaration,
    ) NormalReadError!void {
        self.event_namespace_declarations.ensureTotalCapacity(
            self.allocator,
            declarations.len,
        ) catch return error.OutOfMemory;
        for (declarations) |declaration| {
            self.event_namespace_declarations.appendAssumeCapacity(.{
                .prefix = declaration.prefix,
                .namespace_uri = declaration.namespace_uri,
                .span = null,
                .specified = true,
            });
        }
    }

    fn normalDocumentEnd(
        self: *Self,
        comptime config: Config,
        value: DocumentEnd(config),
    ) NormalDocumentEnd {
        const validity: NormalDtdValidity = if (comptime config.profile.dtdMode() == .validating)
            switch (value.validation) {
                .valid => if (self.external_content_skipped) .incomplete else .valid,
                .invalid => .invalid,
                .incomplete => .incomplete,
            }
        else
            .not_requested;
        const normalization_status = self.engineNormalizationStatus();
        std.debug.assert(normalization_status != .checking);
        const normalization: NormalDocumentNormalization = if (self.effective_version == .xml10)
            .not_applicable
        else switch (normalization_status) {
            .unchecked => .unchecked,
            .checking => .incomplete,
            .normalized => if (self.external_content_skipped) .incomplete else .normalized,
            .not_normalized => .not_normalized,
            .indeterminate => .indeterminate,
        };
        return .{
            .content = if (self.external_content_skipped)
                .external_content_skipped
            else
                .complete,
            .dtd_validity = validity,
            .normalization = normalization,
        };
    }

    fn engineNormalizationStatus(self: *const Self) NormalizationStatus {
        return switch (self.engine) {
            inline else => |*parser| parser.normalizationResult().status,
        };
    }

    fn dtdFindingSink(self: *const Self) ?NormalDtdFindingSink {
        return switch (self.options.dtd) {
            .validate => |options| options.finding_sink,
            else => null,
        };
    }

    fn recordInternalFailure(
        self: *Self,
        comptime config: Config,
        parser: *Reader(config),
        failure: ReadError,
    ) NormalReadError {
        const internal_diagnostic = parser.diagnostic();
        const mapped = mapNormalReadError(failure, if (internal_diagnostic) |value|
            value.code
        else
            null);
        if (mapped == error.InvalidState) return mapped;
        if (self.dtd_finding_copy_failed) {
            const location = self.first_diagnostic.?.primary;
            self.recordGeneratedFailure(error.OutOfMemory, .out_of_memory, location);
            return error.OutOfMemory;
        }
        if (mapped == error.Cancelled and self.dtd_cancel_trace != .none) {
            const finding = self.first_dtd_finding.?;
            self.failure = mapped;
            self.diagnostic_inclusions.clearRetainingCapacity();
            self.first_diagnostic = self.first_diagnostic orelse .{
                .code = .dtd_finding_cancelled,
                .primary = finding.primary,
                .related = null,
            };
            self.reportFatalDiagnostic();
            return mapped;
        }
        if (internal_diagnostic) |value| {
            self.diagnostic_inclusions.clearRetainingCapacity();
            if (comptime config.external_sources) {
                self.diagnostic_inclusions.ensureTotalCapacity(
                    self.allocator,
                    value.inclusion_trace.len,
                ) catch {
                    self.recordGeneratedFailure(
                        error.OutOfMemory,
                        .out_of_memory,
                        normalLocation(
                            self.options.track_lines,
                            AdapterAccess(config).currentLocation(parser),
                        ),
                    );
                    return error.OutOfMemory;
                };
                for (value.inclusion_trace) |source| {
                    self.diagnostic_inclusions.appendAssumeCapacity(
                        normalLocation(self.options.track_lines, source),
                    );
                }
            }
            self.failure = mapped;
            self.first_diagnostic = .{
                .code = value.code,
                .primary = normalLocation(self.options.track_lines, value.primary),
                .related = if (value.related) |related|
                    normalLocation(self.options.track_lines, related)
                else
                    null,
            };
            self.reportFatalDiagnostic();
        } else if (mapped == error.OutOfMemory) {
            self.recordGeneratedFailure(
                mapped,
                .out_of_memory,
                normalLocation(
                    self.options.track_lines,
                    AdapterAccess(config).currentLocation(parser),
                ),
            );
        } else {
            self.failure = mapped;
        }
        return mapped;
    }

    fn recordGeneratedFailure(
        self: *Self,
        failure: NormalReadError,
        code: DiagnosticCode,
        location: NormalLocation,
    ) void {
        self.failure = failure;
        self.diagnostic_inclusions.clearRetainingCapacity();
        self.first_diagnostic = .{
            .code = code,
            .primary = location,
            .related = null,
        };
        self.reportFatalDiagnostic();
    }

    fn reportFatalDiagnostic(self: *const Self) void {
        const sink = self.options.diagnostic_sink orelse return;
        sink.report(self.diagnostic().?);
    }

    fn releaseFacadeStorage(self: *Self) void {
        self.diagnostic_inclusions.deinit(self.allocator);
        self.dtd_finding_inclusions.deinit(self.allocator);
        self.dtd_callback_inclusions.deinit(self.allocator);
        self.event_attributes.deinit(self.allocator);
        self.event_namespace_declarations.deinit(self.allocator);
        self.diagnostic_inclusions = .empty;
        self.dtd_finding_inclusions = .empty;
        self.dtd_callback_inclusions = .empty;
        self.event_attributes = .empty;
        self.event_namespace_declarations = .empty;
    }

    fn commitRootStreamBytes(self: *Self, event_end: u64) void {
        const input = switch (self.source) {
            .slice => return,
            .stream => |value| value,
        };
        if (event_end <= self.source_tossed) return;
        const count = std.math.cast(usize, event_end - self.source_tossed) orelse
            unreachable;
        std.debug.assert(count <= self.pending_toss);
        input.toss(count);
        self.source_tossed += @intCast(count);
        self.pending_toss -= count;
    }
};

fn validNormalOptions(options: NormalReaderOptions) bool {
    if (!options.limits.validate()) return false;
    if (options.external == .resolve and options.resolver == null) return false;
    if (options.external != .resolve and options.resolver != null) return false;
    if (options.external != .resolve and options.document_base_id != null) return false;
    if (options.dtd == .reject and options.external != .forbid) return false;
    return true;
}

fn initNormalEngine(
    allocator: std.mem.Allocator,
    options: NormalReaderOptions,
) NormalInitError!NormalEngine {
    if (options.dtd == .reject) {
        if (options.namespaces == .process) {
            return .{ .namespaces_no_dtd = try initNormalParser(
                normal_namespace_no_dtd_config,
                allocator,
                options,
            ) };
        }
        return .{ .raw_no_dtd = try initNormalParser(
            normal_raw_no_dtd_config,
            allocator,
            options,
        ) };
    }
    const validating = options.dtd == .validate;
    if (validating) {
        if (options.namespaces == .process) {
            return .{ .namespaces_validating = try initNormalParser(
                normal_namespace_validating_config,
                allocator,
                options,
            ) };
        }
        return .{ .raw_validating = try initNormalParser(
            normal_raw_validating_config,
            allocator,
            options,
        ) };
    }
    if (options.namespaces == .process) {
        return .{ .namespaces = try initNormalParser(
            normal_namespace_config,
            allocator,
            options,
        ) };
    }
    return .{ .raw = try initNormalParser(
        normal_raw_config,
        allocator,
        options,
    ) };
}

fn normalEngineKind(options: NormalReaderOptions) std.meta.Tag(NormalEngine) {
    if (options.dtd == .reject) {
        return if (options.namespaces == .process) .namespaces_no_dtd else .raw_no_dtd;
    }
    if (options.dtd == .validate) {
        return if (options.namespaces == .process)
            .namespaces_validating
        else
            .raw_validating;
    }
    return if (options.namespaces == .process) .namespaces else .raw;
}

fn normalOptionsDisableStorage(
    previous: NormalReaderOptions,
    replacement: NormalReaderOptions,
) bool {
    if (previous.dtd != .reject and replacement.dtd == .reject) return true;
    if (previous.transcoder != null and replacement.transcoder == null) return true;
    return previous.external == .resolve and replacement.external != .resolve;
}

fn normalOptionsUseExternalStorage(options: NormalReaderOptions) bool {
    if (options.external == .resolve) return true;
    return switch (options.dtd) {
        .validate => |validation_options| validation_options.external_subset != null,
        else => false,
    };
}

fn normalOptionsUseValidationStorage(options: NormalReaderOptions) bool {
    return options.dtd == .validate;
}

fn resetNormalParser(
    comptime config: Config,
    parser: *Reader(config),
    options: NormalReaderOptions,
    mode: ResetMode,
) void {
    parser.options = normalEngineOptions(config, options);
    parser.reset(mode) catch unreachable;
    configureNormalParser(config, parser, options);
}

fn initNormalParser(
    comptime config: Config,
    allocator: std.mem.Allocator,
    options: NormalReaderOptions,
) NormalInitError!Reader(config) {
    var parser = try Reader(config).init(allocator, normalEngineOptions(config, options));
    configureNormalParser(config, &parser, options);
    return parser;
}

fn configureNormalParser(
    comptime config: Config,
    parser: *Reader(config),
    options: NormalReaderOptions,
) void {
    if (options.transcoder) |transcoder| {
        parser.source_state.encoding = .other;
        parser.source_state.external.transcoder = transcoder;
        parser.source_encoding = .other;
    }
}

fn normalEngineOptions(
    comptime config: Config,
    options: NormalReaderOptions,
) Options(config) {
    var result: Options(config) = .{};
    result.limits = normalParserLimits(options.limits);
    if (comptime config.profile.hasNamespaces()) {
        result.namespace_limits = .{
            .max_declarations_per_element = options.limits.max_namespace_declarations_per_element,
            .max_active_bindings = options.limits.max_active_namespace_bindings,
            .max_binding_bytes = options.limits.max_namespace_binding_bytes,
            .max_qname_bytes = options.limits.max_qname_bytes,
            .max_comparison_work = options.limits.max_namespace_comparison_work,
        };
    }
    if (comptime config.profile.dtdMode() != .rejected) {
        result.dtd_limits = normalDtdLimits(options.limits);
    }
    if (comptime config.external_sources) {
        result.resolver.policy = if (options.external == .resolve) .resolve else .skip;
        result.resolver.resolver = options.resolver;
        result.resolver.document_base_id = options.document_base_id;
        result.resolver.max_resources = options.limits.max_external_resources;
        result.resolver.max_source_bytes = options.limits.max_external_source_bytes;
        result.resolver.max_total_bytes = options.limits.max_external_total_bytes;
        result.resolver.max_identifier_bytes = options.limits.max_external_identifier_bytes;
    }
    result.normalization = switch (options.normalization) {
        .report => .report,
        .require => .require,
        .unchecked => .unchecked,
    };
    if (comptime config.profile.dtdMode() == .validating) {
        result.validation.collect_validity_errors = true;
        result.validation.limits = normalValidationLimits(options.limits);
        if (options.dtd == .validate) {
            result.validation.external_subset = options.dtd.validate.external_subset;
        }
    }
    return result;
}

fn normalParserLimits(limits: NormalLimits) Limits {
    return .{
        .max_depth = limits.max_depth,
        .max_open_name_bytes = limits.max_open_name_bytes,
        .max_partial_token_bytes = limits.max_partial_token_bytes,
        .max_attributes_per_element = limits.max_attributes_per_element,
        .max_attribute_name_bytes = limits.max_attribute_name_bytes,
        .max_attribute_value_bytes = limits.max_attribute_value_bytes,
        .max_attribute_bytes_per_element = limits.max_attribute_bytes_per_element,
        .max_start_tag_bytes = limits.max_start_tag_bytes,
        .max_fragment_bytes = limits.max_fragment_bytes,
        .max_processing_instruction_target_bytes = limits.max_processing_instruction_target_bytes,
        .max_retained_bytes = limits.max_retained_bytes,
    };
}

fn normalDtdLimits(limits: NormalLimits) dtd_module.Limits {
    return .{
        .max_dtd_bytes = limits.max_dtd_bytes,
        .max_declarations = limits.max_dtd_declarations,
        .max_declaration_bytes = limits.max_dtd_declaration_bytes,
        .max_element_declarations = limits.max_dtd_element_declarations,
        .max_attribute_declarations = limits.max_dtd_attribute_declarations,
        .max_entity_declarations = limits.max_dtd_entity_declarations,
        .max_notation_declarations = limits.max_dtd_notation_declarations,
        .max_group_depth = limits.max_dtd_group_depth,
        .max_grammar_nodes = limits.max_dtd_grammar_nodes,
        .max_entity_replacement_bytes = limits.max_dtd_entity_replacement_bytes,
        .max_active_entity_depth = limits.max_dtd_entity_depth,
        .max_entity_references = limits.max_dtd_entity_references,
        .max_expanded_bytes = limits.max_dtd_expanded_bytes,
        .max_expansion_ratio = limits.max_dtd_expansion_ratio,
        .expansion_ratio_minimum_bytes = limits.dtd_expansion_ratio_minimum_bytes,
        .max_comparison_work = limits.max_dtd_comparison_work,
    };
}

fn normalValidationLimits(limits: NormalLimits) validation_module.Limits {
    return .{
        .max_content_positions = limits.max_validation_content_positions,
        .max_content_states = limits.max_validation_content_states,
        .max_content_transitions = limits.max_validation_content_transitions,
        .max_compilation_work = limits.max_validation_compilation_work,
        .max_ids = limits.max_validation_ids,
        .max_idrefs = limits.max_validation_idrefs,
        .max_id_bytes = limits.max_validation_identity_bytes,
        .max_comparison_work = limits.max_validation_comparison_work,
        .max_errors = limits.max_validation_findings,
    };
}

fn normalName(comptime config: Config, name: Name(config)) NormalName {
    if (comptime config.profile.hasNamespaces()) {
        return .{
            .raw = name.raw,
            .expanded = .{
                .prefix = name.prefix,
                .local = name.local,
                .namespace_uri = name.namespace_uri,
            },
        };
    }
    return .{ .raw = name.raw, .expanded = null };
}

fn normalLocation(track_lines: bool, location: anytype) NormalLocation {
    return .{
        .source_id = location.source_id,
        .byte_offset = location.byte_offset,
        .line = if (track_lines and @hasField(@TypeOf(location), "line")) location.line else null,
        .byte_column = if (track_lines and @hasField(@TypeOf(location), "byte_column"))
            location.byte_column
        else
            null,
    };
}

fn normalSpan(comptime config: Config, span: Span(config)) NormalSourceSpan {
    std.debug.assert(span.start.source_id == span.end.source_id);
    return .{
        .source_id = span.start.source_id,
        .start = span.start.byte_offset,
        .end = span.end.byte_offset,
    };
}

fn mapNormalReadError(failure: ReadError, code: ?DiagnosticCode) NormalReadError {
    return switch (failure) {
        error.InvalidXml => if (code) |value|
            switch (value) {
                .malformed_utf8,
                .malformed_encoding,
                .missing_encoding_signature,
                .encoding_mismatch,
                => error.InvalidEncoding,
                .unsupported_version => error.UnsupportedVersion,
                .unsupported_encoding => error.UnsupportedEncoding,
                else => error.InvalidXml,
            }
        else
            error.InvalidXml,
        error.InvalidDtd => if (code == .external_subset_mismatch)
            error.ExternalResourceFailed
        else
            error.InvalidXml,
        error.NotValid => error.InvalidXml,
        error.UnsupportedFeature => if (code) |value|
            switch (value) {
                .unsupported_version => error.UnsupportedVersion,
                .unsupported_encoding => error.UnsupportedEncoding,
                .dtd_forbidden => error.DtdForbidden,
                .external_resource_forbidden => error.ExternalResourceForbidden,
                else => error.InvalidXml,
            }
        else
            error.InvalidXml,
        error.LimitExceeded => error.LimitExceeded,
        error.ResolverFailed => switch (code orelse .resolver_io_failure) {
            .resolver_forbidden, .external_resource_forbidden => error.ExternalResourceForbidden,
            .resolver_not_found, .resolver_unsupported_scheme => error.ExternalResourceUnavailable,
            else => error.ExternalResourceFailed,
        },
        error.ReadFailed => if (code == .resolver_io_failure)
            error.ExternalResourceFailed
        else
            error.ReadFailed,
        error.Cancelled => error.Cancelled,
        error.NotNormalized => error.NotNormalized,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidState => error.InvalidState,
    };
}

fn normalValidityReporter(
    comptime config: Config,
) *const fn (?*anyopaque, Diagnostic(config)) ValidityAction {
    return struct {
        fn report(context: ?*anyopaque, diagnostic: Diagnostic(config)) ValidityAction {
            const self: *NormalReader = @ptrCast(@alignCast(context.?));
            const core: NormalDtdFindingCore = .{
                .code = diagnostic.code,
                .primary = normalLocation(self.options.track_lines, diagnostic.primary),
                .related = if (diagnostic.related) |related|
                    normalLocation(self.options.track_lines, related)
                else
                    null,
            };
            const first = self.first_dtd_finding == null;
            const inclusions = if (first) &self.dtd_finding_inclusions else &self.dtd_callback_inclusions;
            std.debug.assert(
                diagnostic.inclusion_trace.len <= self.options.limits.max_dtd_entity_depth,
            );
            inclusions.ensureTotalCapacityPrecise(
                self.allocator,
                diagnostic.inclusion_trace.len,
            ) catch {
                self.dtd_finding_copy_failed = true;
                self.first_diagnostic = .{
                    .code = .out_of_memory,
                    .primary = core.primary,
                    .related = null,
                };
                return .cancel;
            };
            inclusions.clearRetainingCapacity();
            for (diagnostic.inclusion_trace) |location| {
                inclusions.appendAssumeCapacity(normalLocation(
                    self.options.track_lines,
                    location,
                ));
            }
            if (first) self.first_dtd_finding = core;
            const sink = self.dtdFindingSink() orelse return .continue_validation;
            const action = sink.report(.{
                .code = core.code,
                .primary = core.primary,
                .related = core.related,
                .inclusion_trace = inclusions.items,
            });
            if (action == .cancel) {
                self.dtd_cancel_trace = if (first) .first_finding else .later_finding;
                self.first_diagnostic = .{
                    .code = .dtd_finding_cancelled,
                    .primary = core.primary,
                    .related = null,
                };
            }
            return switch (action) {
                .continue_validation => .continue_validation,
                .cancel => .cancel,
            };
        }
    }.report;
}

/// Internal bridge used by package adapters without exposing parser state.
pub fn AdapterAccess(comptime config: Config) type {
    return struct {
        pub fn recordReadFailure(reader: *Reader(config)) ReadError {
            return reader.fail(.read_failed, .read_failed);
        }

        pub fn currentLocation(reader: *const Reader(config)) Location(config) {
            return reader.currentLocation();
        }

        pub fn feedTranscodedRoot(
            reader: *Reader(config),
            input: []const u8,
            final: bool,
        ) ReadError!void {
            return reader.feedTranscodedRoot(input, final);
        }

        pub fn transcoderPendingInput(reader: *const Reader(config)) usize {
            return reader.source_state.raw_input.len - reader.source_state.raw_cursor;
        }
    };
}

fn isXmlWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isAsciiNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':';
}

fn isAsciiNameChar(byte: u8) bool {
    return isAsciiNameStart(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '.';
}

fn isOrdinaryAttributeValueByte(byte: u8, quote: u8) bool {
    return byte >= ' ' and byte < 0x80 and byte != quote and byte != '&' and byte != '<';
}

fn isXml10Char(codepoint: u32) bool {
    return codepoint == 0x9 or codepoint == 0xa or codepoint == 0xd or
        (codepoint >= 0x20 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

fn isXml11Char(codepoint: u32) bool {
    return (codepoint >= 0x1 and codepoint <= 0xd7ff) or
        (codepoint >= 0xe000 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0x10ffff);
}

fn isXml11RestrictedChar(codepoint: u32) bool {
    return (codepoint >= 0x1 and codepoint <= 0x8) or
        (codepoint >= 0xb and codepoint <= 0xc) or
        (codepoint >= 0xe and codepoint <= 0x1f) or
        (codepoint >= 0x7f and codepoint <= 0x84) or
        (codepoint >= 0x86 and codepoint <= 0x9f);
}

fn isXmlLiteralChar(codepoint: u32, version: XmlVersion) bool {
    return switch (version) {
        .xml10 => isXml10Char(codepoint),
        .xml11 => isXml11Char(codepoint) and !isXml11RestrictedChar(codepoint),
    };
}

fn hasForbiddenAsciiControl(bytes: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const space: Vector = @splat(0x20);
        const tab: Vector = @splat('\t');
        const line_feed: Vector = @splat('\n');
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const block: Vector = bytes[index..][0..vector_len].*;
            const forbidden = (block < space) & (block != tab) & (block != line_feed);
            if (@reduce(.Or, forbidden)) return true;
        }
    }
    for (bytes[index..]) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\n') return true;
    }
    return false;
}

const ContentStructureScan = struct {
    delimiter_index: usize,
    has_non_ascii: bool,
};

fn contentStartsUnicodeDense(bytes: []const u8) bool {
    for (bytes[0..@min(bytes.len, 8)]) |byte| if (byte >= 0x80) return true;
    return false;
}

noinline fn scanContentStructure(bytes: []const u8) ContentStructureScan {
    var index: usize = 0;
    var has_non_ascii = false;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const mask: Vector = @splat(0x80);
        const less_than: Vector = @splat('<');
        const ampersand: Vector = @splat('&');
        const carriage_return: Vector = @splat('\r');
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const block: Vector = bytes[index..][0..vector_len].*;
            const delimiter = (block == less_than) | (block == ampersand) |
                (block == carriage_return);
            if (@reduce(.Or, delimiter)) {
                for (bytes[index..][0..vector_len], 0..) |byte, relative| {
                    if (byte == '<' or byte == '&' or byte == '\r') {
                        return .{
                            .delimiter_index = index + relative,
                            .has_non_ascii = has_non_ascii,
                        };
                    }
                    has_non_ascii = has_non_ascii or byte >= 0x80;
                }
                unreachable;
            }
            has_non_ascii = has_non_ascii or @reduce(.Or, block & mask == mask);
        }
    }
    for (bytes[index..], index..) |byte, position| {
        if (byte == '<' or byte == '&' or byte == '\r') {
            return .{ .delimiter_index = position, .has_non_ascii = has_non_ascii };
        }
        has_non_ascii = has_non_ascii or byte >= 0x80;
    }
    return .{ .delimiter_index = bytes.len, .has_non_ascii = has_non_ascii };
}

fn hasNonAscii(bytes: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const mask: Vector = @splat(0x80);
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const block: Vector = bytes[index..][0..vector_len].*;
            if (@reduce(.Or, block & mask == mask)) return true;
        }
    }
    for (bytes[index..]) |byte| if (byte >= 0x80) return true;
    return false;
}

noinline fn utf8AndXmlControlsValid(bytes: []const u8) bool {
    var index: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |vector_len| {
        const Vector = @Vector(vector_len, u8);
        const c2: Vector = @splat(0xc2);
        const e0: Vector = @splat(0xe0);
        const ed: Vector = @splat(0xed);
        const f0: Vector = @splat(0xf0);
        const f4: Vector = @splat(0xf4);
        const ff: Vector = @splat(0xff);
        const fe: Vector = @splat(0xfe);
        const bf: Vector = @splat(0xbf);
        const continuation_low: Vector = @splat(0x80);
        const continuation_high: Vector = @splat(0xbf);
        const a0: Vector = @splat(0xa0);
        const nine_f: Vector = @splat(0x9f);
        const nine_zero: Vector = @splat(0x90);
        const eight_f: Vector = @splat(0x8f);
        const space: Vector = @splat(0x20);
        const tab: Vector = @splat('\t');
        const line_feed: Vector = @splat('\n');

        while (index < @min(bytes.len, 3)) : (index += 1) {
            if (!utf8XmlByteValid(bytes, index)) return false;
        }
        while (index + vector_len <= bytes.len) : (index += vector_len) {
            const current: Vector = bytes[index..][0..vector_len].*;
            const previous1: Vector = bytes[index - 1 ..][0..vector_len].*;
            const previous2: Vector = bytes[index - 2 ..][0..vector_len].*;
            const previous3: Vector = bytes[index - 3 ..][0..vector_len].*;

            const continuation = (current >= continuation_low) &
                (current <= continuation_high);
            const expected = ((previous1 >= c2) & (previous1 <= f4)) |
                ((previous2 >= e0) & (previous2 <= f4)) |
                ((previous3 >= f0) & (previous3 <= f4));
            const invalid_leader = ((current >= @as(Vector, @splat(0xc0))) &
                (current < c2)) | (current > f4);
            const invalid_boundary = ((previous1 == e0) & (current < a0)) |
                ((previous1 == ed) & (current > nine_f)) |
                ((previous1 == f0) & (current < nine_zero)) |
                ((previous1 == f4) & (current > eight_f));
            const forbidden_noncharacter = (previous2 == @as(Vector, @splat(0xef))) &
                (previous1 == bf) & ((current == fe) | (current == ff));
            const forbidden_control = (current < space) &
                (current != tab) &
                (current != line_feed);
            if (@reduce(.Or, (continuation != expected) | invalid_leader |
                invalid_boundary | forbidden_noncharacter | forbidden_control))
            {
                return false;
            }
        }
    }
    while (index < bytes.len) : (index += 1) {
        if (!utf8XmlByteValid(bytes, index)) return false;
    }
    if (bytes.len > 0 and isUtf8Leader(bytes[bytes.len - 1])) return false;
    if (bytes.len > 1 and isUtf8ThreeOrFourByteLeader(bytes[bytes.len - 2])) return false;
    if (bytes.len > 2 and isUtf8FourByteLeader(bytes[bytes.len - 3])) return false;
    return true;
}

fn utf8XmlByteValid(bytes: []const u8, index: usize) bool {
    const byte = bytes[index];
    const continuation = byte >= 0x80 and byte <= 0xbf;
    const expected = (index >= 1 and isUtf8Leader(bytes[index - 1])) or
        (index >= 2 and isUtf8ThreeOrFourByteLeader(bytes[index - 2])) or
        (index >= 3 and isUtf8FourByteLeader(bytes[index - 3]));
    if (continuation != expected or byte == 0xc0 or byte == 0xc1 or byte > 0xf4) return false;
    if (index >= 1) {
        const previous = bytes[index - 1];
        if ((previous == 0xe0 and byte < 0xa0) or
            (previous == 0xed and byte > 0x9f) or
            (previous == 0xf0 and byte < 0x90) or
            (previous == 0xf4 and byte > 0x8f))
        {
            return false;
        }
    }
    if (index >= 2 and bytes[index - 2] == 0xef and bytes[index - 1] == 0xbf and
        (byte == 0xbe or byte == 0xbf)) return false;
    return byte >= 0x20 or byte == '\t' or byte == '\n';
}

fn isUtf8Leader(byte: u8) bool {
    return byte >= 0xc2 and byte <= 0xf4;
}

fn isUtf8ThreeOrFourByteLeader(byte: u8) bool {
    return byte >= 0xe0 and byte <= 0xf4;
}

fn isUtf8FourByteLeader(byte: u8) bool {
    return byte >= 0xf0 and byte <= 0xf4;
}

// --- Tests ---

test "[unit] - [normal Reader DTD policy]: rejection selects no-DTD engines" {
    var namespace_rejecting = try NormalReader.init(
        std.testing.allocator,
        .{ .slice = "<root/>" },
        .{ .dtd = .reject },
    );
    defer namespace_rejecting.deinit();
    try std.testing.expectEqual(
        std.meta.Tag(NormalEngine).namespaces_no_dtd,
        std.meta.activeTag(namespace_rejecting.engine),
    );

    var raw_rejecting = try NormalReader.init(
        std.testing.allocator,
        .{ .slice = "<root/>" },
        .{ .namespaces = .raw, .dtd = .reject },
    );
    defer raw_rejecting.deinit();
    try std.testing.expectEqual(
        std.meta.Tag(NormalEngine).raw_no_dtd,
        std.meta.activeTag(raw_rejecting.engine),
    );

    var namespace_processing = try NormalReader.init(
        std.testing.allocator,
        .{ .slice = "<root/>" },
        .{},
    );
    defer namespace_processing.deinit();
    try std.testing.expectEqual(
        std.meta.Tag(NormalEngine).namespaces,
        std.meta.activeTag(namespace_processing.engine),
    );

    var raw_processing = try NormalReader.init(
        std.testing.allocator,
        .{ .slice = "<root/>" },
        .{ .namespaces = .raw },
    );
    defer raw_processing.deinit();
    try std.testing.expectEqual(
        std.meta.Tag(NormalEngine).raw,
        std.meta.activeTag(raw_processing.engine),
    );
}

test "[unit] - [content SIMD]: forbidden-control scan matches scalar boundaries" {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    var storage: [2 * vector_len + 1]u8 = undefined;
    const lengths = [_]usize{ vector_len - 1, vector_len, vector_len + 1, storage.len };
    for (lengths) |length| {
        const bytes = storage[0..length];
        @memset(bytes, 'x');
        try std.testing.expect(!hasForbiddenAsciiControl(bytes));
        for (0..length) |position| {
            for (0..256) |value| {
                bytes[position] = @intCast(value);
                const expected = value < 0x20 and value != '\t' and value != '\n';
                try std.testing.expectEqual(expected, hasForbiddenAsciiControl(bytes));
            }
            bytes[position] = 'x';
        }
    }
}

test "[unit] - [content SIMD]: UTF-8 and XML-control scan matches reference" {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    var storage: [2 * vector_len + 7]u8 = undefined;
    const pattern = "a\xc3\xa9\xce\xbb\xf0\x9f\x99\x82";
    for (&storage, 0..) |*byte, index| byte.* = pattern[index % pattern.len];

    const lengths = [_]usize{
        0,
        1,
        vector_len - 1,
        vector_len,
        vector_len + 1,
        2 * vector_len - 1,
        2 * vector_len,
        storage.len,
    };
    for (lengths) |length| {
        for (0..length) |position| {
            const original = storage[position];
            for (0..256) |value| {
                storage[position] = @intCast(value);
                const bytes = storage[0..length];
                const expected = std.unicode.utf8ValidateSlice(bytes) and
                    !hasForbiddenAsciiControl(bytes) and
                    std.mem.indexOf(u8, bytes, "\xef\xbf\xbe") == null and
                    std.mem.indexOf(u8, bytes, "\xef\xbf\xbf") == null;
                try std.testing.expectEqual(expected, utf8AndXmlControlsValid(bytes));
            }
            storage[position] = original;
        }
    }

    var prng = std.Random.DefaultPrng.init(0x757466385f786d6c);
    const random = prng.random();
    for (0..10_000) |_| {
        const length = random.intRangeAtMost(usize, 0, storage.len);
        random.bytes(storage[0..length]);
        const bytes = storage[0..length];
        const expected = std.unicode.utf8ValidateSlice(bytes) and
            !hasForbiddenAsciiControl(bytes) and
            std.mem.indexOf(u8, bytes, "\xef\xbf\xbe") == null and
            std.mem.indexOf(u8, bytes, "\xef\xbf\xbf") == null;
        try std.testing.expectEqual(expected, utf8AndXmlControlsValid(bytes));
    }
}

test "[unit] - [content SIMD]: structural scan matches scalar boundaries" {
    const vector_len = std.simd.suggestVectorLength(u8) orelse 16;
    var storage: [2 * vector_len + 1]u8 = undefined;
    const lengths = [_]usize{ vector_len - 1, vector_len, vector_len + 1, storage.len };
    for (lengths) |length| {
        const bytes = storage[0..length];
        @memset(bytes, 'x');
        for (0..length) |position| {
            for (0..256) |value| {
                bytes[position] = @intCast(value);
                var expected_index = length;
                var expected_non_ascii = false;
                for (bytes, 0..) |byte, index| {
                    if (byte == '<' or byte == '&' or byte == '\r') {
                        expected_index = index;
                        break;
                    }
                    expected_non_ascii = expected_non_ascii or byte >= 0x80;
                }
                const observed = scanContentStructure(bytes);
                try std.testing.expectEqual(expected_index, observed.delimiter_index);
                try std.testing.expectEqual(expected_non_ascii, observed.has_non_ascii);
            }
            bytes[position] = 'x';
        }
    }
}

fn isXml10NameStart(codepoint: u32) bool {
    return codepoint == ':' or
        (codepoint >= 'A' and codepoint <= 'Z') or
        codepoint == '_' or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0xc0 and codepoint <= 0xd6) or
        (codepoint >= 0xd8 and codepoint <= 0xf6) or
        (codepoint >= 0xf8 and codepoint <= 0x2ff) or
        (codepoint >= 0x370 and codepoint <= 0x37d) or
        (codepoint >= 0x37f and codepoint <= 0x1fff) or
        (codepoint >= 0x200c and codepoint <= 0x200d) or
        (codepoint >= 0x2070 and codepoint <= 0x218f) or
        (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
        (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
        (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
        (codepoint >= 0x10000 and codepoint <= 0xeffff);
}

fn isXml10NameChar(codepoint: u32) bool {
    return isXml10NameStart(codepoint) or codepoint == '-' or codepoint == '.' or
        (codepoint >= '0' and codepoint <= '9') or codepoint == 0xb7 or
        (codepoint >= 0x300 and codepoint <= 0x36f) or
        (codepoint >= 0x203f and codepoint <= 0x2040);
}

fn probeUtf8(bytes: []const u8) Utf8Probe {
    std.debug.assert(bytes.len > 0);
    const lead = bytes[0];
    const expected: u3 = if (lead < 0x80)
        1
    else if (lead >= 0xc2 and lead <= 0xdf)
        2
    else if (lead >= 0xe0 and lead <= 0xef)
        3
    else if (lead >= 0xf0 and lead <= 0xf4)
        4
    else
        return .{ .invalid = 0 };
    if (bytes.len < expected) {
        for (bytes[1..], 1..) |byte, index| {
            if (byte < 0x80 or byte > 0xbf) return .{ .invalid = index };
            if (index == 1 and !validUtf8SecondByte(lead, byte)) {
                return .{ .invalid = index };
            }
        }
        return .incomplete;
    }
    for (bytes[1..expected], 1..) |byte, index| {
        if (byte < 0x80 or byte > 0xbf) return .{ .invalid = index };
        if (index == 1 and !validUtf8SecondByte(lead, byte)) {
            return .{ .invalid = index };
        }
    }
    const codepoint = std.unicode.utf8Decode(bytes[0..expected]) catch unreachable;
    return .{ .scalar = .{ .codepoint = codepoint, .len = expected } };
}

fn validUtf8SecondByte(lead: u8, byte: u8) bool {
    if (lead == 0xe0) return byte >= 0xa0;
    if (lead == 0xed) return byte <= 0x9f;
    if (lead == 0xf0) return byte >= 0x90;
    if (lead == 0xf4) return byte <= 0x8f;
    return true;
}

fn utf8ExpectedLength(lead: u8) ?u3 {
    if (lead < 0x80) return 1;
    if (lead >= 0xc2 and lead <= 0xdf) return 2;
    if (lead >= 0xe0 and lead <= 0xef) return 3;
    if (lead >= 0xf0 and lead <= 0xf4) return 4;
    return null;
}

fn referenceDigit(byte: u8, kind: ReferenceKind) ?u32 {
    return switch (kind) {
        .decimal => if (byte >= '0' and byte <= '9') byte - '0' else null,
        .hexadecimal => if (byte >= '0' and byte <= '9')
            byte - '0'
        else if (byte >= 'a' and byte <= 'f')
            byte - 'a' + 10
        else if (byte >= 'A' and byte <= 'F')
            byte - 'A' + 10
        else
            null,
    };
}

fn predefinedEntity(name: []const u8, source_len: usize) ?[]const u8 {
    if (source_len != name.len) return null;
    if (std.mem.eql(u8, name, "amp")) return "&";
    if (std.mem.eql(u8, name, "lt")) return "<";
    if (std.mem.eql(u8, name, "gt")) return ">";
    if (std.mem.eql(u8, name, "apos")) return "'";
    if (std.mem.eql(u8, name, "quot")) return "\"";
    return null;
}

fn locationWithByteDelta(
    comptime config: Config,
    location: Location(config),
    delta: usize,
) Location(config) {
    var result = location;
    result.byte_offset += delta;
    if (config.diagnostic_location == .line_column) result.byte_column += delta;
    return result;
}

fn locationFromSource(comptime config: Config, source_id: u32, byte_offset: usize) Location(config) {
    if (config.diagnostic_location == .line_column) {
        return .{
            .source_id = source_id,
            .byte_offset = byte_offset,
            .line = 1,
            .byte_column = byte_offset + 1,
        };
    }
    return .{ .source_id = source_id, .byte_offset = byte_offset };
}

fn nameFromRaw(comptime config: Config, raw: []const u8) Name(config) {
    if (comptime config.profile.hasNamespaces()) {
        return .{
            .raw = raw,
            .prefix = null,
            .local = raw,
            .namespace_uri = null,
        };
    }
    return .{ .raw = raw };
}
