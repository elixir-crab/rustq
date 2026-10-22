use rustler::{Encoder, Env, NifResult, Term};
use syn::File;

mod decode;
mod generated_ast;
mod parse;
mod parse_item;
mod parse_type;
mod syn_metadata;
mod template;
mod unstable_syntax;

pub(crate) use decode::*;
pub(crate) use parse::*;
pub(crate) use parse_item::*;
pub(crate) use parse_type::*;
use template::{render_source, template_error};

use generated_ast::{atoms, decode_ast_item};

#[rustler::nif(schedule = "DirtyCpu")]
fn parse<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    match syn::parse_file(&source) {
        Ok(_) => Ok(atoms::ok().encode(env)),
        Err(error) => Ok((atoms::error(), vec![template_error(error)]).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn render<'a>(
    env: Env<'a>,
    source: String,
    bindings: Vec<(String, String)>,
    splices: Vec<(String, Vec<String>)>,
) -> NifResult<Term<'a>> {
    match render_source(&source, bindings, splices) {
        Ok(code) => Ok((atoms::ok(), code).encode(env)),
        Err(errors) => Ok((atoms::error(), errors).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn render_ast(ast: Term) -> NifResult<String> {
    let item = decode_ast_item(ast)?;
    let source = prettyplease::unparse(&File {
        shebang: None,
        attrs: Vec::new(),
        items: vec![item],
    });

    // Nodes built without parsing, such as a function named `self`, can still unparse into
    // Rust that does not parse; report them rather than return it.
    syn::parse_file(&source).map_err(|error| {
        rustler::Error::Term(Box::new(format!("renders invalid Rust: {error}")))
    })?;

    Ok(source)
}

#[rustler::nif]
fn rust_identifier(name: String, context: String) -> NifResult<String> {
    parse::identifier_source(&name, &context)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn syn_inspect<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    syn_metadata::inspect_source(env, source)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn syn_inspect_unstable<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    syn_metadata::inspect_unstable_source(env, source)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn syn_atom_references<'a>(env: Env<'a>, source: String, module: String) -> NifResult<Term<'a>> {
    syn_metadata::atom_references(env, source, module)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn syn_method_references<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    syn_metadata::method_references(env, source)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn syn_method_calls<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    syn_metadata::method_calls(env, source)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn syn_enum_variants<'a>(env: Env<'a>, source: String, enum_name: String) -> NifResult<Term<'a>> {
    syn_metadata::enum_variants(env, source, enum_name)
}

rustler::init!("Elixir.RustQ.Native.Nif");
