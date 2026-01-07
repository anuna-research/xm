// SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
// SPDX-License-Identifier: AGPL-3.0-or-later

//! C FFI bindings for Oxigraph
//!
//! This crate exposes Oxigraph's RDF store functionality via C ABI,
//! allowing Guile Scheme to interact with the SPARQL engine.

use libc::{c_char, c_int, size_t};
use oxigraph::io::{RdfFormat, RdfParser, RdfSerializer};
use oxigraph::model::{GraphNameRef, NamedNodeRef, Quad, Term};
use oxigraph::sparql::QueryResults;
use oxigraph::store::Store;
use std::ffi::CStr;
use std::ptr;
use uuid::Uuid;

/// Opaque handle to an Oxigraph store
pub struct XmStore {
    store: Store,
}

/// Error codes returned by FFI functions
#[repr(C)]
pub enum XmError {
    Ok = 0,
    NullPointer = -1,
    InvalidUtf8 = -2,
    StoreError = -3,
    QueryError = -4,
    SerializationError = -5,
    BufferTooSmall = -6,
    InvalidFormat = -7,
}

// ============================================================================
// Store Lifecycle
// ============================================================================

/// Open or create an Oxigraph store at the given path.
///
/// # Safety
/// - `path` must be a valid null-terminated C string
/// - Returns NULL on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_open(path: *const c_char) -> *mut XmStore {
    if path.is_null() {
        return ptr::null_mut();
    }

    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => return ptr::null_mut(),
    };

    match Store::open(path_str) {
        Ok(store) => Box::into_raw(Box::new(XmStore { store })),
        Err(_) => ptr::null_mut(),
    }
}

/// Open an in-memory Oxigraph store (for testing).
///
/// # Safety
/// - Returns NULL on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_open_memory() -> *mut XmStore {
    match Store::new() {
        Ok(store) => Box::into_raw(Box::new(XmStore { store })),
        Err(_) => ptr::null_mut(),
    }
}

/// Close and free an Oxigraph store.
///
/// # Safety
/// - `store` must be a valid pointer returned by `xm_store_open*`
/// - After calling, `store` is invalid and must not be used
#[no_mangle]
pub unsafe extern "C" fn xm_store_close(store: *mut XmStore) {
    if !store.is_null() {
        drop(Box::from_raw(store));
    }
}

// ============================================================================
// SPARQL Query
// ============================================================================

/// Execute a SPARQL SELECT query and write JSON results to buffer.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `sparql` must be a valid null-terminated SPARQL query
/// - `result_buf` must point to a buffer of at least `buf_len` bytes
/// - Returns number of bytes written, or negative error code
#[no_mangle]
#[allow(deprecated)]
pub unsafe extern "C" fn xm_store_query(
    store: *mut XmStore,
    sparql: *const c_char,
    result_buf: *mut c_char,
    buf_len: size_t,
) -> c_int {
    if store.is_null() || sparql.is_null() || result_buf.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let sparql_str = match CStr::from_ptr(sparql).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let results = match store.query(sparql_str) {
        Ok(r) => r,
        Err(_) => return XmError::QueryError as c_int,
    };

    let json_str = match results_to_json(results) {
        Ok(s) => s,
        Err(_) => return XmError::SerializationError as c_int,
    };

    let json_bytes = json_str.as_bytes();
    if json_bytes.len() >= buf_len {
        return XmError::BufferTooSmall as c_int;
    }

    ptr::copy_nonoverlapping(json_bytes.as_ptr(), result_buf as *mut u8, json_bytes.len());
    *result_buf.add(json_bytes.len()) = 0; // null-terminate

    json_bytes.len() as c_int
}

/// Execute a SPARQL UPDATE (INSERT/DELETE) query.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `sparql` must be a valid null-terminated SPARQL update query
/// - Returns 0 on success, negative error code on failure
#[no_mangle]
pub unsafe extern "C" fn xm_store_update(store: *mut XmStore, sparql: *const c_char) -> c_int {
    if store.is_null() || sparql.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let sparql_str = match CStr::from_ptr(sparql).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    match store.update(sparql_str) {
        Ok(_) => XmError::Ok as c_int,
        Err(_) => XmError::QueryError as c_int,
    }
}

// ============================================================================
// Direct Quad Operations
// ============================================================================

/// Insert a single quad into the store.
///
/// # Safety
/// - All string parameters must be valid null-terminated C strings
/// - `graph` may be NULL for the default graph
/// - Returns 0 on success, negative error code on failure
#[no_mangle]
pub unsafe extern "C" fn xm_store_insert_quad(
    store: *mut XmStore,
    subject: *const c_char,
    predicate: *const c_char,
    object: *const c_char,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || subject.is_null() || predicate.is_null() || object.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;

    let subject_str = match CStr::from_ptr(subject).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };
    let predicate_str = match CStr::from_ptr(predicate).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };
    let object_str = match CStr::from_ptr(object).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_name = if graph.is_null() {
        GraphNameRef::DefaultGraph
    } else {
        match CStr::from_ptr(graph).to_str() {
            Ok(s) => GraphNameRef::NamedNode(match NamedNodeRef::new(s) {
                Ok(n) => n,
                Err(_) => return XmError::InvalidUtf8 as c_int,
            }),
            Err(_) => return XmError::InvalidUtf8 as c_int,
        }
    };

    // Parse subject as named node
    let subj = match NamedNodeRef::new(subject_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    // Parse predicate as named node
    let pred = match NamedNodeRef::new(predicate_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    // Parse object - try as named node first, then as literal
    let obj: Term = if object_str.starts_with("http://") || object_str.starts_with("https://") {
        match NamedNodeRef::new(object_str) {
            Ok(n) => n.into(),
            Err(_) => return XmError::InvalidUtf8 as c_int,
        }
    } else {
        oxigraph::model::Literal::new_simple_literal(object_str).into()
    };

    let quad = Quad::new(subj, pred, obj, graph_name);
    match store.insert(&quad) {
        Ok(_) => XmError::Ok as c_int,
        Err(_) => XmError::StoreError as c_int,
    }
}

/// Delete a single quad from the store.
///
/// # Safety
/// - All string parameters must be valid null-terminated C strings
/// - `graph` may be NULL for the default graph
/// - Returns 0 on success, negative error code on failure
#[no_mangle]
pub unsafe extern "C" fn xm_store_delete_quad(
    store: *mut XmStore,
    subject: *const c_char,
    predicate: *const c_char,
    object: *const c_char,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || subject.is_null() || predicate.is_null() || object.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;

    let subject_str = match CStr::from_ptr(subject).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };
    let predicate_str = match CStr::from_ptr(predicate).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };
    let object_str = match CStr::from_ptr(object).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_name = if graph.is_null() {
        GraphNameRef::DefaultGraph
    } else {
        match CStr::from_ptr(graph).to_str() {
            Ok(s) => GraphNameRef::NamedNode(match NamedNodeRef::new(s) {
                Ok(n) => n,
                Err(_) => return XmError::InvalidUtf8 as c_int,
            }),
            Err(_) => return XmError::InvalidUtf8 as c_int,
        }
    };

    let subj = match NamedNodeRef::new(subject_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };
    let pred = match NamedNodeRef::new(predicate_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };
    let obj: Term = if object_str.starts_with("http://") || object_str.starts_with("https://") {
        match NamedNodeRef::new(object_str) {
            Ok(n) => n.into(),
            Err(_) => return XmError::InvalidUtf8 as c_int,
        }
    } else {
        oxigraph::model::Literal::new_simple_literal(object_str).into()
    };

    let quad = Quad::new(subj, pred, obj, graph_name);
    match store.remove(&quad) {
        Ok(_) => XmError::Ok as c_int,
        Err(_) => XmError::StoreError as c_int,
    }
}

// ============================================================================
// Serialization / Deserialization
// ============================================================================

/// Dump a named graph to Turtle format.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid graph URI or NULL for default graph
/// - `format` must be one of: "turtle", "ntriples", "nquads"
/// - `buf` must point to a buffer of at least `buf_len` bytes
/// - Returns bytes written, or negative error code
#[no_mangle]
#[allow(deprecated)]
pub unsafe extern "C" fn xm_store_dump_graph(
    store: *mut XmStore,
    graph: *const c_char,
    format: *const c_char,
    buf: *mut c_char,
    buf_len: size_t,
) -> c_int {
    if store.is_null() || format.is_null() || buf.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;

    let format_str = match CStr::from_ptr(format).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let rdf_format = match format_str {
        "turtle" => RdfFormat::Turtle,
        "ntriples" => RdfFormat::NTriples,
        "nquads" => RdfFormat::NQuads,
        _ => return XmError::InvalidFormat as c_int,
    };

    let graph_name = if graph.is_null() {
        None
    } else {
        match CStr::from_ptr(graph).to_str() {
            Ok(s) => Some(s),
            Err(_) => return XmError::InvalidUtf8 as c_int,
        }
    };

    let mut output = Vec::new();

    // Build SPARQL query to get all triples in the graph
    let query = match graph_name {
        Some(g) => format!("CONSTRUCT {{ ?s ?p ?o }} WHERE {{ GRAPH <{}> {{ ?s ?p ?o }} }}", g),
        None => "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }".to_string(),
    };

    let results = match store.query(&query) {
        Ok(r) => r,
        Err(_) => return XmError::QueryError as c_int,
    };

    if let QueryResults::Graph(triples) = results {
        let mut serializer = RdfSerializer::from_format(rdf_format).for_writer(&mut output);
        for triple_result in triples {
            match triple_result {
                Ok(triple) => {
                    if serializer.serialize_triple(&triple).is_err() {
                        return XmError::SerializationError as c_int;
                    }
                }
                Err(_) => return XmError::QueryError as c_int,
            }
        }
        if serializer.finish().is_err() {
            return XmError::SerializationError as c_int;
        }
    }

    if output.len() >= buf_len {
        return XmError::BufferTooSmall as c_int;
    }

    ptr::copy_nonoverlapping(output.as_ptr(), buf as *mut u8, output.len());
    *buf.add(output.len()) = 0;

    output.len() as c_int
}

/// Dump ALL quads from the store (including all named graphs) to N-Quads format.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `buf` must point to a buffer of at least `buf_len` bytes
/// - Returns bytes written, or negative error code
#[no_mangle]
pub unsafe extern "C" fn xm_store_dump_all(
    store: *mut XmStore,
    buf: *mut c_char,
    buf_len: size_t,
) -> c_int {
    if store.is_null() || buf.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let mut output = Vec::new();

    // Iterate over all quads and serialize to N-Quads
    for quad_result in store.iter() {
        match quad_result {
            Ok(quad) => {
                // Format as N-Quads line
                let subj = format_subject(&quad.subject);
                let pred = format!("<{}>", quad.predicate.as_str());
                let obj = format_object(&quad.object);

                let line = match &quad.graph_name {
                    oxigraph::model::GraphName::DefaultGraph => {
                        format!("{} {} {} .\n", subj, pred, obj)
                    }
                    oxigraph::model::GraphName::NamedNode(g) => {
                        format!("{} {} {} <{}> .\n", subj, pred, obj, g.as_str())
                    }
                    oxigraph::model::GraphName::BlankNode(b) => {
                        format!("{} {} {} _:{} .\n", subj, pred, obj, b.as_str())
                    }
                };
                output.extend_from_slice(line.as_bytes());
            }
            Err(_) => return XmError::StoreError as c_int,
        }
    }

    if output.len() >= buf_len {
        return XmError::BufferTooSmall as c_int;
    }

    ptr::copy_nonoverlapping(output.as_ptr(), buf as *mut u8, output.len());
    *buf.add(output.len()) = 0;

    output.len() as c_int
}

fn format_subject(subj: &oxigraph::model::NamedOrBlankNode) -> String {
    match subj {
        oxigraph::model::NamedOrBlankNode::NamedNode(n) => format!("<{}>", n.as_str()),
        oxigraph::model::NamedOrBlankNode::BlankNode(b) => format!("_:{}", b.as_str()),
    }
}

fn format_object(obj: &Term) -> String {
    match obj {
        Term::NamedNode(n) => format!("<{}>", n.as_str()),
        Term::BlankNode(b) => format!("_:{}", b.as_str()),
        Term::Literal(l) => {
            if let Some(lang) = l.language() {
                format!("\"{}\"@{}", escape_string(l.value()), lang)
            } else if l.datatype() == oxigraph::model::vocab::xsd::STRING {
                format!("\"{}\"", escape_string(l.value()))
            } else {
                format!("\"{}\"^^<{}>", escape_string(l.value()), l.datatype().as_str())
            }
        }
    }
}

fn escape_string(s: &str) -> String {
    let mut result = String::new();
    for c in s.chars() {
        match c {
            '\\' => result.push_str("\\\\"),
            '"' => result.push_str("\\\""),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            '\t' => result.push_str("\\t"),
            _ => result.push(c),
        }
    }
    result
}

/// Load RDF data into a named graph.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid graph URI or NULL for default graph
/// - `format` must be one of: "turtle", "ntriples", "nquads"
/// - `data` must be a valid null-terminated string of RDF data
/// - Returns 0 on success, negative error code on failure
#[no_mangle]
pub unsafe extern "C" fn xm_store_load_graph(
    store: *mut XmStore,
    graph: *const c_char,
    format: *const c_char,
    data: *const c_char,
) -> c_int {
    if store.is_null() || format.is_null() || data.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;

    let format_str = match CStr::from_ptr(format).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let data_str = match CStr::from_ptr(data).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let rdf_format = match format_str {
        "turtle" => RdfFormat::Turtle,
        "ntriples" => RdfFormat::NTriples,
        "nquads" => RdfFormat::NQuads,
        _ => return XmError::InvalidFormat as c_int,
    };

    let graph_name = if graph.is_null() {
        GraphNameRef::DefaultGraph
    } else {
        match CStr::from_ptr(graph).to_str() {
            Ok(s) => GraphNameRef::NamedNode(match NamedNodeRef::new(s) {
                Ok(n) => n,
                Err(_) => return XmError::InvalidUtf8 as c_int,
            }),
            Err(_) => return XmError::InvalidUtf8 as c_int,
        }
    };

    let parser = RdfParser::from_format(rdf_format);
    for quad_result in parser.for_reader(data_str.as_bytes()) {
        match quad_result {
            Ok(quad) => {
                // For N-Quads with no explicit target graph, preserve the graph from the data
                // For other formats or explicit target graph, use the specified graph
                let target_graph = if graph.is_null() && rdf_format == RdfFormat::NQuads {
                    // Preserve original graph from N-Quads data
                    quad.graph_name.clone()
                } else {
                    graph_name.into()
                };

                let new_quad = Quad::new(
                    quad.subject.clone(),
                    quad.predicate.clone(),
                    quad.object.clone(),
                    target_graph,
                );
                if store.insert(&new_quad).is_err() {
                    return XmError::StoreError as c_int;
                }
            }
            Err(_) => return XmError::SerializationError as c_int,
        }
    }

    XmError::Ok as c_int
}

// ============================================================================
// Statistics
// ============================================================================

/// Get the number of quads in the store.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - Returns count or negative error code
#[no_mangle]
pub unsafe extern "C" fn xm_store_count(store: *mut XmStore) -> c_int {
    if store.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    match store.len() {
        Ok(count) => count as c_int,
        Err(_) => XmError::StoreError as c_int,
    }
}

/// Check if the store is empty.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - Returns 1 if empty, 0 if not empty, negative on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_is_empty(store: *mut XmStore) -> c_int {
    if store.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    match store.is_empty() {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => XmError::StoreError as c_int,
    }
}

// ============================================================================
// Named Graph Operations
// ============================================================================

/// List all named graphs in the store, returning JSON array of URIs.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `buf` must point to a buffer of at least `buf_len` bytes
/// - Returns bytes written, or negative error code
#[no_mangle]
pub unsafe extern "C" fn xm_store_list_graphs(
    store: *mut XmStore,
    buf: *mut c_char,
    buf_len: size_t,
) -> c_int {
    if store.is_null() || buf.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let mut graphs: Vec<String> = Vec::new();

    for graph_result in store.named_graphs() {
        match graph_result {
            Ok(graph) => {
                if let oxigraph::model::NamedOrBlankNode::NamedNode(n) = graph {
                    graphs.push(n.into_string());
                }
            }
            Err(_) => return XmError::StoreError as c_int,
        }
    }

    let json_str = match serde_json::to_string(&graphs) {
        Ok(s) => s,
        Err(_) => return XmError::SerializationError as c_int,
    };

    let json_bytes = json_str.as_bytes();
    if json_bytes.len() >= buf_len {
        return XmError::BufferTooSmall as c_int;
    }

    ptr::copy_nonoverlapping(json_bytes.as_ptr(), buf as *mut u8, json_bytes.len());
    *buf.add(json_bytes.len()) = 0;

    json_bytes.len() as c_int
}

/// Check if a named graph exists in the store.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid null-terminated URI string
/// - Returns 1 if exists, 0 if not, negative on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_graph_exists(
    store: *mut XmStore,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || graph.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let graph_str = match CStr::from_ptr(graph).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_ref = match NamedNodeRef::new(graph_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    match store.contains_named_graph(graph_ref) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => XmError::StoreError as c_int,
    }
}

/// Create an empty named graph (inserts graph name into store).
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid null-terminated URI string
/// - Returns 0 on success, negative on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_create_graph(
    store: *mut XmStore,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || graph.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let graph_str = match CStr::from_ptr(graph).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_ref = match NamedNodeRef::new(graph_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    match store.insert_named_graph(graph_ref) {
        Ok(_) => XmError::Ok as c_int,
        Err(_) => XmError::StoreError as c_int,
    }
}

/// Drop a named graph and all its triples.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid null-terminated URI string
/// - Returns 0 on success, negative on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_drop_graph(
    store: *mut XmStore,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || graph.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let graph_str = match CStr::from_ptr(graph).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_ref = match NamedNodeRef::new(graph_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    match store.remove_named_graph(graph_ref) {
        Ok(_) => XmError::Ok as c_int,
        Err(_) => XmError::StoreError as c_int,
    }
}

/// Clear all triples in a named graph (graph name remains).
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid null-terminated URI string
/// - Returns 0 on success, negative on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_clear_graph(
    store: *mut XmStore,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || graph.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let graph_str = match CStr::from_ptr(graph).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_ref = match NamedNodeRef::new(graph_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    match store.clear_graph(graph_ref) {
        Ok(_) => XmError::Ok as c_int,
        Err(_) => XmError::StoreError as c_int,
    }
}

/// Count quads in a specific named graph.
///
/// # Safety
/// - `store` must be a valid store pointer
/// - `graph` must be a valid null-terminated URI string
/// - Returns count, or negative on error
#[no_mangle]
pub unsafe extern "C" fn xm_store_graph_count(
    store: *mut XmStore,
    graph: *const c_char,
) -> c_int {
    if store.is_null() || graph.is_null() {
        return XmError::NullPointer as c_int;
    }

    let store = &(*store).store;
    let graph_str = match CStr::from_ptr(graph).to_str() {
        Ok(s) => s,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_ref = match NamedNodeRef::new(graph_str) {
        Ok(n) => n,
        Err(_) => return XmError::InvalidUtf8 as c_int,
    };

    let graph_name = GraphNameRef::NamedNode(graph_ref);
    let count = store
        .quads_for_pattern(None, None, None, Some(graph_name))
        .count();

    count as c_int
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert SPARQL query results to JSON string (SPARQL JSON Results format)
fn results_to_json(results: QueryResults) -> Result<String, ()> {
    match results {
        QueryResults::Solutions(solutions) => {
            let vars: Vec<String> = solutions.variables().iter().map(|v| v.as_str().to_string()).collect();
            let mut bindings = Vec::new();

            for solution_result in solutions {
                let solution = solution_result.map_err(|_| ())?;
                let mut binding = std::collections::HashMap::new();

                for var in &vars {
                    if let Some(term) = solution.get(var.as_str()) {
                        binding.insert(var.clone(), term_to_json_value(term));
                    }
                }
                bindings.push(binding);
            }

            let result = serde_json::json!({
                "head": { "vars": vars },
                "results": { "bindings": bindings }
            });

            serde_json::to_string(&result).map_err(|_| ())
        }
        QueryResults::Boolean(b) => {
            let result = serde_json::json!({
                "head": {},
                "boolean": b
            });
            serde_json::to_string(&result).map_err(|_| ())
        }
        QueryResults::Graph(_) => {
            // For CONSTRUCT queries, return empty for now
            // The dump function handles graph serialization
            Ok(r#"{"type":"graph"}"#.to_string())
        }
    }
}

fn term_to_json_value(term: &Term) -> serde_json::Value {
    match term {
        Term::NamedNode(n) => serde_json::json!({
            "type": "uri",
            "value": n.as_str()
        }),
        Term::BlankNode(b) => serde_json::json!({
            "type": "bnode",
            "value": b.as_str()
        }),
        Term::Literal(l) => {
            let mut obj = serde_json::json!({
                "type": "literal",
                "value": l.value()
            });
            if let Some(lang) = l.language() {
                obj["xml:lang"] = serde_json::json!(lang);
            } else if l.datatype() != oxigraph::model::vocab::xsd::STRING {
                obj["datatype"] = serde_json::json!(l.datatype().as_str());
            }
            obj
        }
    }
}

// ============================================================================
// UUID Generation
// ============================================================================

/// Generate a new UUID v4 and write it to the buffer.
///
/// # Safety
/// - `buf` must point to a buffer of at least 37 bytes (36 chars + null)
/// - Returns number of bytes written (36) or negative error code
#[no_mangle]
pub unsafe extern "C" fn xm_uuid_generate(buf: *mut c_char, buf_len: size_t) -> c_int {
    if buf.is_null() {
        return XmError::NullPointer as c_int;
    }

    if buf_len < 37 {
        return XmError::BufferTooSmall as c_int;
    }

    let uuid = Uuid::new_v4();
    let uuid_str = uuid.to_string();
    let uuid_bytes = uuid_str.as_bytes();

    ptr::copy_nonoverlapping(uuid_bytes.as_ptr(), buf as *mut u8, uuid_bytes.len());
    *buf.add(uuid_bytes.len()) = 0; // null-terminate

    uuid_bytes.len() as c_int
}
