use quote::{format_ident, quote, ToTokens};
use rustler::{NifResult, Term};
use syn::{Arm, Expr, LitInt, Pat, Stmt, Type};

use crate::generated_ast::{
    atom, atom_key, decode_ast_expr, decode_ast_pat, decode_ast_type, decode_function_arg, is_nil,
    optional_map_get, struct_name,
};
use crate::{ident_from_part, parse_expr, parse_syn, path_from_parts};

// Primitive-boundary inventory:
// - Forever primitive: Rustler Term APIs, atom/string conversion, map/list traversal.
// - Generic glue: optional decoding and typed named-field collection.
// - Concrete list traversal is generated from Rusty-Elixir in generated_ast.rs.
// - Parse assembly belongs in parse.rs, parse_item.rs, or parse_type.rs, not here.
pub(crate) fn decode_function_arg_value(term: Term) -> NifResult<syn::FnArg> {
    match decode_function_arg(term) {
        Ok(arg) => Ok(arg),
        Err(_) => {
            let (name, ty) = term.decode::<(Term, Term)>()?;
            let name = format_ident!("{}", atom_or_string(name)?);
            let ty = decode_type(ty)?;
            crate::parse_function_arg(name, ty, false)
        }
    }
}

// Rust syntax attribute/visibility decoders shared by handwritten and generated code.
pub(crate) fn decode_vis(term: Term) -> NifResult<syn::Visibility> {
    if is_nil(term)? {
        syn::parse2(quote!()).map_err(|_| rustler::Error::BadArg)
    } else {
        match term.atom_to_string()?.as_str() {
            "pub" => syn::parse2(quote!(pub)).map_err(|_| rustler::Error::BadArg),
            "crate" => syn::parse2(quote!(pub(crate))).map_err(|_| rustler::Error::BadArg),
            _ => Err(rustler::Error::BadArg),
        }
    }
}

pub(crate) fn decode_derive(term: Term) -> NifResult<Vec<syn::Attribute>> {
    let paths = crate::generated_ast::decode_derive_path_list(term)?;

    if paths.is_empty() {
        Ok(Vec::new())
    } else {
        Ok(vec![syn::parse_quote!(#[derive(#(#paths),*)])])
    }
}

enum AttributeArg {
    Ident(proc_macro2::Ident),
    Path(syn::Path),
    NameValueString(proc_macro2::Ident, String),
}

impl ToTokens for AttributeArg {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        match self {
            AttributeArg::Ident(ident) => tokens.extend(quote!(#ident)),
            AttributeArg::Path(path) => tokens.extend(quote!(#path)),
            AttributeArg::NameValueString(ident, value) => tokens.extend(quote!(#ident = #value)),
        }
    }
}

fn decode_attribute_value(term: Term) -> NifResult<String> {
    if let Ok(value) = term.decode::<String>() {
        Ok(value)
    } else {
        atom_or_string(term)
    }
}

pub(crate) fn decode_attribute_list(term: Term) -> NifResult<Vec<syn::Attribute>> {
    term.decode::<Vec<Term>>()?
        .into_iter()
        .map(decode_attribute)
        .collect()
}

fn decode_attribute(term: Term) -> NifResult<syn::Attribute> {
    let path = path_from_parts(decode_string_list(
        term.map_get(atom(term.get_env(), "path")?)?,
    )?)?;
    let arg_term = term.map_get(atom(term.get_env(), "args")?)?;

    if let Ok((tag, value)) = arg_term.decode::<(Term, Term)>() {
        if atom_or_string(tag)? == "value" {
            let value = decode_attribute_value(value)?;
            return parse_syn(quote!(#[#path = #value]));
        }
    }

    let args = decode_attribute_args(arg_term)?;

    if args.is_empty() {
        parse_syn(quote!(#[#path]))
    } else {
        parse_syn(quote!(#[#path(#(#args),*)]))
    }
}

fn decode_attribute_args(term: Term) -> NifResult<Vec<AttributeArg>> {
    if let Ok(args) = term.decode::<Vec<(Term, Term)>>() {
        return args
            .into_iter()
            .map(|(key, value)| {
                Ok(AttributeArg::NameValueString(
                    format_ident!("{}", atom_or_string(key)?),
                    decode_attribute_value(value)?,
                ))
            })
            .collect();
    }

    term.decode::<Vec<Term>>()?
        .into_iter()
        .map(decode_attribute_arg)
        .collect()
}

fn decode_attribute_arg(term: Term) -> NifResult<AttributeArg> {
    if struct_name(term).ok().as_deref() == Some("Elixir.RustQ.Rust.AST.Path") {
        let path = path_from_parts(decode_string_list(
            term.map_get(atom(term.get_env(), "parts")?)?,
        )?)?;

        return Ok(AttributeArg::Path(path));
    }

    Ok(AttributeArg::Ident(format_ident!(
        "{}",
        atom_or_string(term)?
    )))
}

pub(crate) fn decode_derive_path_terms(term: Term) -> NifResult<Vec<Term>> {
    term.decode::<Vec<Term>>()?
        .into_iter()
        .map(|term| {
            if struct_name(term).ok().as_deref() == Some("Elixir.RustQ.Rust.AST.Derive") {
                term.map_get(atom(term.get_env(), "paths")?)?
                    .decode::<Vec<Term>>()
            } else {
                Ok(vec![term])
            }
        })
        .collect::<NifResult<Vec<Vec<Term>>>>()
        .map(|terms| terms.into_iter().flatten().collect())
}

pub(crate) fn decode_path_value(term: Term) -> NifResult<syn::Path> {
    let parts = if let Ok(parts) = term.decode::<Vec<Term>>() {
        parts
            .into_iter()
            .map(atom_or_string)
            .collect::<NifResult<Vec<String>>>()?
    } else {
        vec![atom_or_string(term)?]
    };

    path_from_parts(parts)
}

pub(crate) fn decode_stmt_list(term: Term) -> NifResult<Vec<Stmt>> {
    crate::generated_ast::decode_stmt_list(term)
}

pub(crate) fn decode_block(term: Term) -> NifResult<syn::Block> {
    let stmts = decode_stmt_list(term)?;
    syn::parse2::<syn::Block>(quote!({ #(#stmts)* })).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn parse_block_arm(pat: Pat, block: syn::Block) -> NifResult<Arm> {
    Ok(Arm {
        attrs: Vec::new(),
        pat,
        guard: None,
        fat_arrow_token: Default::default(),
        body: Box::new(Expr::Block(syn::ExprBlock {
            attrs: Vec::new(),
            label: None,
            block,
        })),
        comma: Some(Default::default()),
    })
}

pub(crate) fn parse_guarded_block_arm(
    pat: Pat,
    guard: Option<Expr>,
    block: syn::Block,
) -> NifResult<Arm> {
    if let Some(guard) = guard {
        parse_syn::<Arm>(quote!(#pat if #guard => #block,))
    } else {
        parse_block_arm(pat, block)
    }
}

pub(crate) fn decode_optional_block_field(
    term: Term,
    field: &str,
) -> NifResult<Option<syn::Block>> {
    let value = term.map_get(atom(term.get_env(), field)?)?;
    let values = value.decode::<Vec<Term>>()?;

    if values.is_empty() {
        Ok(None)
    } else {
        Ok(Some(decode_block(value)?))
    }
}

pub(crate) fn decode_let_pattern(pat: Pat, mutable: bool) -> NifResult<proc_macro2::TokenStream> {
    if mutable {
        let Pat::Ident(mut pat_ident) = pat else {
            return Err(rustler::Error::BadArg);
        };
        pat_ident.mutability = Some(Default::default());
        Ok(quote!(#pat_ident))
    } else {
        Ok(quote!(#pat))
    }
}

pub(crate) fn parse_let_stmt(
    pat_tokens: proc_macro2::TokenStream,
    ty: Option<Type>,
    expr: Expr,
) -> NifResult<Stmt> {
    if let Some(ty) = ty {
        parse_syn::<Stmt>(quote!(let #pat_tokens: #ty = #expr;))
    } else {
        parse_syn::<Stmt>(quote!(let #pat_tokens = #expr;))
    }
}

pub(crate) fn parse_let_else_stmt(pat: Pat, expr: Expr, else_block: syn::Block) -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(let #pat = #expr else #else_block;))
}

pub(crate) fn parse_assign_stmt(target: Expr, expr: Expr) -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(#target = #expr;))
}

pub(crate) fn parse_assign_op_stmt(target: Expr, op: &str, expr: Expr) -> NifResult<Stmt> {
    match op {
        "add" => parse_syn::<Stmt>(quote!(#target += #expr;)),
        "sub" => parse_syn::<Stmt>(quote!(#target -= #expr;)),
        "mul" => parse_syn::<Stmt>(quote!(#target *= #expr;)),
        "div" => parse_syn::<Stmt>(quote!(#target /= #expr;)),
        "shr" => parse_syn::<Stmt>(quote!(#target >>= #expr;)),
        "bitand" => parse_syn::<Stmt>(quote!(#target &= #expr;)),
        other => Err(rustler::Error::Term(Box::new(format!(
            "unsupported assignment operator: {other}"
        )))),
    }
}

pub(crate) fn parse_return_stmt(expr: Expr) -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(return #expr;))
}

pub(crate) fn parse_block_expr(block: syn::Block) -> NifResult<Expr> {
    Ok(Expr::Block(syn::ExprBlock {
        attrs: Vec::new(),
        label: None,
        block,
    }))
}

pub(crate) fn parse_unsafe_block_expr(block: syn::Block) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(unsafe #block))
}

pub(crate) fn parse_if_expr(
    condition: Expr,
    then_block: syn::Block,
    else_block: Option<syn::Block>,
) -> NifResult<Expr> {
    if let Some(else_block) = else_block {
        parse_syn::<Expr>(quote!(if #condition #then_block else #else_block))
    } else {
        parse_syn::<Expr>(quote!(if #condition #then_block))
    }
}

pub(crate) fn parse_if_let_stmt(
    pattern: Pat,
    expr: Expr,
    then_block: syn::Block,
    else_block: Option<syn::Block>,
) -> NifResult<Stmt> {
    if let Some(else_block) = else_block {
        parse_syn::<Stmt>(quote!(if let #pattern = #expr #then_block else #else_block))
    } else {
        parse_syn::<Stmt>(quote!(if let #pattern = #expr #then_block))
    }
}

pub(crate) fn parse_for_stmt(pattern: Pat, expr: Expr, body: syn::Block) -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(for #pattern in #expr #body))
}

pub(crate) fn parse_loop_stmt(body: syn::Block) -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(loop #body))
}

pub(crate) fn parse_break_stmt(expr: Option<Expr>) -> NifResult<Stmt> {
    if let Some(expr) = expr {
        parse_syn::<Stmt>(quote!(break #expr;))
    } else {
        parse_syn::<Stmt>(quote!(break;))
    }
}

pub(crate) fn parse_continue_stmt() -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(continue;))
}

pub(crate) fn decode_expr(term: Term) -> NifResult<Expr> {
    decode_ast_expr(term)
}

// syn parser helpers used as explicit Rusty-Elixir primitive boundaries.
pub(crate) fn parse_ident_expr(ident: proc_macro2::Ident) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(#ident))
}

pub(crate) fn parse_ref_expr(expr: Expr, mutable: bool) -> NifResult<Expr> {
    if mutable {
        parse_syn::<Expr>(quote!(&mut #expr))
    } else {
        parse_syn::<Expr>(quote!(&#expr))
    }
}

pub(crate) fn parse_struct_literal_expr(
    path: Expr,
    fields: Vec<NamedField<Expr>>,
) -> NifResult<Expr> {
    let Expr::Path(path) = path else {
        return Err(rustler::Error::BadArg);
    };

    parse_syn::<Expr>(quote!(#path { #(#fields),* }))
}

pub(crate) fn parse_raise_atom_expr(name: String) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(rustler::Error::RaiseAtom(#name)))
}

pub(crate) fn parse_binary_expr(left: Expr, op: String, right: Expr) -> NifResult<Expr> {
    match op.as_str() {
        "eq" => parse_syn::<Expr>(quote!(#left == #right)),
        "ne" => parse_syn::<Expr>(quote!(#left != #right)),
        "lt" => parse_syn::<Expr>(quote!(#left < #right)),
        "lte" => parse_syn::<Expr>(quote!(#left <= #right)),
        "gt" => parse_syn::<Expr>(quote!(#left > #right)),
        "gte" => parse_syn::<Expr>(quote!(#left >= #right)),
        "add" => parse_syn::<Expr>(quote!(#left + #right)),
        "sub" => parse_syn::<Expr>(quote!(#left - #right)),
        "mul" => parse_syn::<Expr>(quote!(#left * #right)),
        "div" => parse_syn::<Expr>(quote!(#left / #right)),
        "rem" => parse_syn::<Expr>(quote!(#left % #right)),
        "and" => parse_syn::<Expr>(quote!(#left && #right)),
        "or" => parse_syn::<Expr>(quote!(#left || #right)),
        "shr" => parse_syn::<Expr>(quote!(#left >> #right)),
        "bitand" => parse_syn::<Expr>(quote!(#left & #right)),
        _ => Err(rustler::Error::BadArg),
    }
}

pub(crate) fn parse_match_expr(expr: Expr, arms: Vec<Arm>) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(match #expr { #(#arms)* }))
}

pub(crate) fn parse_tuple_expr(values: Vec<Expr>) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!((#(#values),*)))
}

pub(crate) fn parse_vec_expr(values: Vec<Expr>) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(vec![#(#values),*]))
}

pub(crate) fn parse_closure_expr(args: Vec<proc_macro2::Ident>, body: Expr) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(|#(#args),*| #body))
}

pub(crate) fn parse_macro_call_expr(path: syn::Path, args: Vec<Expr>) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(#path!(#(#args),*)))
}

pub(crate) fn parse_ok_expr(expr: Option<Expr>) -> NifResult<Expr> {
    if let Some(expr) = expr {
        parse_syn::<Expr>(quote!(Ok(#expr)))
    } else {
        parse_syn::<Expr>(quote!(Ok(())))
    }
}

pub(crate) fn parse_none_expr(_term: Term) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(None))
}

pub(crate) fn parse_some_expr(expr: Expr) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(Some(#expr)))
}

pub(crate) fn parse_err_expr(expr: Expr) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(Err(#expr)))
}

pub(crate) fn parse_try_expr(expr: Expr) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(#expr?))
}

pub(crate) fn parse_expr_stmt(expr: Expr) -> NifResult<Stmt> {
    parse_syn::<Stmt>(quote!(#expr;))
}

pub(crate) fn parse_path_call_expr(
    path: syn::Path,
    args: Vec<Expr>,
    generics: Vec<Type>,
) -> NifResult<Expr> {
    if generics.is_empty() {
        parse_syn::<Expr>(quote!(#path(#(#args),*)))
    } else {
        parse_syn::<Expr>(quote!(#path::<#(#generics),*>(#(#args),*)))
    }
}

pub(crate) fn parse_method_call_expr(
    receiver: Expr,
    method: proc_macro2::Ident,
    args: Vec<Expr>,
    generics: Vec<Type>,
) -> NifResult<Expr> {
    if method_receiver_needs_grouping(&receiver) {
        if generics.is_empty() {
            parse_syn::<Expr>(quote!((#receiver).#method(#(#args),*)))
        } else {
            parse_syn::<Expr>(quote!((#receiver).#method::<#(#generics),*>(#(#args),*)))
        }
    } else if generics.is_empty() {
        parse_syn::<Expr>(quote!(#receiver.#method(#(#args),*)))
    } else {
        parse_syn::<Expr>(quote!(#receiver.#method::<#(#generics),*>(#(#args),*)))
    }
}

fn method_receiver_needs_grouping(receiver: &Expr) -> bool {
    matches!(receiver, Expr::Binary(_) | Expr::Cast(_))
}

pub(crate) fn parse_field_expr(receiver: Expr, field: Term) -> NifResult<Expr> {
    if let Ok(index) = field.decode::<u32>() {
        let index = syn::Index::from(index as usize);
        return parse_syn::<Expr>(quote!(#receiver.#index));
    }

    let field = format_ident!("{}", atom_or_string(field)?);
    parse_syn::<Expr>(quote!(#receiver.#field))
}

pub(crate) fn parse_index_expr(receiver: Expr, index: Expr) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(#receiver[#index]))
}

pub(crate) fn parse_range_expr(
    start: Option<Expr>,
    stop: Option<Expr>,
    inclusive: bool,
) -> NifResult<Expr> {
    match (start, stop, inclusive) {
        (Some(start), Some(stop), true) => parse_syn::<Expr>(quote!(#start..=#stop)),
        (None, Some(stop), true) => parse_syn::<Expr>(quote!(..=#stop)),
        (Some(start), Some(stop), false) => parse_syn::<Expr>(quote!(#start..#stop)),
        (Some(start), None, false) => parse_syn::<Expr>(quote!(#start..)),
        (None, Some(stop), false) => parse_syn::<Expr>(quote!(..#stop)),
        (None, None, false) => parse_syn::<Expr>(quote!(..)),
        _ => Err(rustler::Error::BadArg),
    }
}

pub(crate) fn parse_cast_expr(expr: Expr, ty: Type) -> NifResult<Expr> {
    if matches!(expr, Expr::Binary(_)) {
        parse_syn::<Expr>(quote!((#expr) as #ty))
    } else {
        parse_syn::<Expr>(quote!(#expr as #ty))
    }
}

pub(crate) fn parse_unary_expr(op: String, expr: Expr) -> NifResult<Expr> {
    match op.as_str() {
        "not" => parse_syn::<Expr>(quote!( !#expr )),
        "neg" => parse_syn::<Expr>(quote!( -#expr )),
        "deref" => parse_syn::<Expr>(quote!( *#expr )),
        _ => Err(rustler::Error::BadArg),
    }
}

pub(crate) fn parse_byte_string_expr(value: String) -> NifResult<Expr> {
    let bytes = proc_macro2::Literal::byte_string(value.as_bytes());
    parse_syn::<Expr>(quote!(#bytes))
}

pub(crate) fn parse_array_expr(values: Vec<Expr>) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!([#(#values),*]))
}

pub(crate) fn parse_macro_repeat_expr(
    expr: Expr,
    separator: String,
    operator: String,
) -> NifResult<Expr> {
    let separator = proc_macro2::Literal::string(&separator);
    let operator = proc_macro2::Literal::string(&operator);
    parse_syn::<Expr>(quote!(macro_repeat!(#expr, #separator, #operator)))
}

pub(crate) fn parse_local_call(name: String, args: Vec<Expr>) -> NifResult<Expr> {
    if name.ends_with('!') {
        return Err(rustler::Error::BadArg);
    }

    let name = format_ident!("{}", name);
    parse_syn::<Expr>(quote!(#name(#(#args),*)))
}

pub(crate) struct NamedField<T> {
    name: proc_macro2::Ident,
    value: T,
}

impl<T: ToTokens> ToTokens for NamedField<T> {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        let name = &self.name;
        let value = &self.value;
        tokens.extend(quote!(#name: #value));
    }
}

pub(crate) fn decode_struct_literal_fields(term: Term) -> NifResult<Vec<NamedField<Expr>>> {
    decode_named_field_list(term, decode_expr)
}

pub(crate) fn decode_atom_guard_arm(pat_term: Term, block: syn::Block) -> NifResult<Arm> {
    let name = format_ident_value(atom_key(pat_term, "name")?);
    parse_syn::<Arm>(quote!(value if value == atoms::#name() => #block,))
}

pub(crate) fn format_ident_value(name: String) -> proc_macro2::Ident {
    ident_from_part(&name)
}

pub(crate) fn parse_ast_path(term: Term) -> NifResult<syn::Path> {
    path_from_parts(decode_string_list(
        term.map_get(atom(term.get_env(), "parts")?)?,
    )?)
}

pub(crate) fn parse_path_expr(path: syn::Path) -> NifResult<Expr> {
    parse_syn::<Expr>(quote!(#path))
}

pub(crate) fn parse_atom_value_expr(
    module: Vec<String>,
    name: proc_macro2::Ident,
) -> NifResult<Expr> {
    let module = path_from_parts(module)?;
    parse_syn::<Expr>(quote!(#module::#name()))
}

pub(crate) fn parse_item_use_group_term(term: Term) -> NifResult<syn::ItemUse> {
    let (base, names) = term.decode::<(Term, Term)>()?;
    crate::parse_item_use_group(decode_string_list(base)?, decode_string_list(names)?)
}

pub(crate) fn string_field(term: Term, key: &str) -> NifResult<String> {
    term.map_get(atom(term.get_env(), key)?)?.decode()
}

pub(crate) fn decode_optional_field<T>(
    term: Term,
    key: &str,
    decoder: fn(Term) -> NifResult<T>,
) -> NifResult<Option<T>> {
    match optional_map_get(term, key)? {
        Some(value) if !is_nil(value)? => Ok(Some(decoder(value)?)),
        _ => Ok(None),
    }
}

pub(crate) fn decode_optional_type_field(term: Term, key: &str) -> NifResult<Option<Type>> {
    decode_optional_field(term, key, decode_type)
}

pub(crate) fn decode_optional_expr_field(term: Term, key: &str) -> NifResult<Option<Expr>> {
    decode_optional_field(term, key, decode_expr)
}

pub(crate) fn decode_optional_pat_field(term: Term, key: &str) -> NifResult<Option<Pat>> {
    decode_optional_field(term, key, decode_pat)
}

enum LiteralTerm {
    Bool(bool),
    I64(i64),
    F64(f64),
    String(String),
    Atom(String),
}

fn decode_literal_term(term: Term) -> NifResult<LiteralTerm> {
    if let Ok(value) = term.decode::<bool>() {
        return Ok(LiteralTerm::Bool(value));
    }
    if let Ok(value) = term.decode::<i64>() {
        return Ok(LiteralTerm::I64(value));
    }
    if let Ok(value) = term.decode::<f64>() {
        return Ok(LiteralTerm::F64(value));
    }
    if let Ok(value) = term.decode::<String>() {
        return Ok(LiteralTerm::String(value));
    }
    if term.is_atom() {
        return Ok(LiteralTerm::Atom(term.atom_to_string()?));
    }
    Err(rustler::Error::BadArg)
}

pub(crate) fn parse_var_pat(ident: proc_macro2::Ident, mutable: bool) -> NifResult<Pat> {
    if mutable {
        parse_syn::<Pat>(quote!(mut #ident))
    } else {
        parse_syn::<Pat>(quote!(#ident))
    }
}

pub(crate) fn parse_wildcard_pat(_term: Term) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(_))
}

pub(crate) fn parse_none_pat(_term: Term) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(None))
}

pub(crate) fn parse_path_pat(path: syn::Path) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(#path))
}

pub(crate) fn parse_some_pat(pat: Pat) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(Some(#pat)))
}

pub(crate) fn parse_ok_pat(pat: Pat) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(Ok(#pat)))
}

pub(crate) fn parse_err_pat(pat: Pat) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(Err(#pat)))
}

pub(crate) fn parse_tuple_pat(patterns: Vec<Pat>) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!((#(#patterns),*)))
}

pub(crate) fn parse_path_tuple_pat(path: syn::Path, patterns: Vec<Pat>) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(#path(#(#patterns),*)))
}

pub(crate) fn parse_struct_pat(path: syn::Path, fields: Vec<NamedField<Pat>>) -> NifResult<Pat> {
    parse_syn::<Pat>(quote!(#path { #(#fields),* }))
}

pub(crate) fn parse_slice_pat(patterns: Vec<Pat>, rest: Option<Pat>) -> NifResult<Pat> {
    match rest {
        Some(rest) => parse_syn::<Pat>(quote!([#(#patterns),*, #rest @ ..])),
        None => parse_syn::<Pat>(quote!([#(#patterns),*])),
    }
}

pub(crate) fn decode_pat_literal_value(term: Term) -> NifResult<Pat> {
    match decode_literal_term(term)? {
        LiteralTerm::Bool(true) => parse_syn::<Pat>(quote!(true)),
        LiteralTerm::Bool(false) => parse_syn::<Pat>(quote!(false)),
        LiteralTerm::I64(value) => {
            let literal = LitInt::new(&value.to_string(), proc_macro2::Span::call_site());
            parse_syn::<Pat>(quote!(#literal))
        }
        LiteralTerm::F64(value) => parse_syn::<Pat>(quote!(#value)),
        LiteralTerm::String(value) | LiteralTerm::Atom(value) => parse_syn::<Pat>(quote!(#value)),
    }
}

pub(crate) fn decode_pat(term: Term) -> NifResult<Pat> {
    decode_ast_pat(term)
}

pub(crate) fn decode_pat_atom_guard(_term: Term) -> NifResult<Pat> {
    Err(rustler::Error::BadArg)
}

pub(crate) fn decode_named_field_list<T>(
    term: Term,
    decoder: fn(Term) -> NifResult<T>,
) -> NifResult<Vec<NamedField<T>>> {
    term.decode::<Vec<(Term, Term)>>()?
        .into_iter()
        .map(|(name, value)| {
            Ok(NamedField {
                name: format_ident!("{}", atom_or_string(name)?),
                value: decoder(value)?,
            })
        })
        .collect()
}

pub(crate) fn decode_pat_struct_fields(term: Term) -> NifResult<Vec<NamedField<Pat>>> {
    decode_named_field_list(term, decode_pat)
}

pub(crate) fn decode_ident_list(term: Term) -> NifResult<Vec<proc_macro2::Ident>> {
    decode_string_list(term).map(|names| {
        names
            .into_iter()
            .map(|name| format_ident!("{}", name))
            .collect()
    })
}

pub(crate) fn decode_literal_expr(term: Term) -> NifResult<Expr> {
    match decode_literal_term(term)? {
        LiteralTerm::Bool(true) => parse_syn::<Expr>(quote!(true)),
        LiteralTerm::Bool(false) => parse_syn::<Expr>(quote!(false)),
        LiteralTerm::I64(value) => parse_expr(value.to_string()),
        LiteralTerm::F64(value) => parse_expr(format_float_literal(value)),
        LiteralTerm::String(value) => parse_syn::<Expr>(quote!(#value)),
        LiteralTerm::Atom(_) => Err(rustler::Error::BadArg),
    }
}

fn format_float_literal(value: f64) -> String {
    let formatted = value.to_string();

    if formatted.contains('.') || formatted.contains('e') || formatted.contains('E') {
        formatted
    } else {
        format!("{formatted}.0")
    }
}

pub(crate) fn path_parts(term: Term) -> NifResult<String> {
    crate::generated_ast::path_parts(term)
}

pub(crate) fn atom_or_string(term: Term) -> NifResult<String> {
    if term.is_atom() {
        term.atom_to_string()
    } else {
        term.decode::<String>()
    }
}

pub(crate) fn decode_type(term: Term) -> NifResult<Type> {
    decode_ast_type(term)
}

pub(crate) fn decode_string_list(term: Term) -> NifResult<Vec<String>> {
    crate::generated_ast::decode_string_list(term)
}
