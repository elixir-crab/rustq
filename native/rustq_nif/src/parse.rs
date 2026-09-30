use rustler::NifResult;
use syn::parse::Parser;
use syn::{Arm, Block, Expr, Pat, Stmt, Type};

pub(crate) trait ParseSynTokens: Sized {
    fn parse_syn_tokens(tokens: proc_macro2::TokenStream) -> syn::Result<Self>;
}

macro_rules! impl_parse_syn_tokens {
    ($($type:ty),+ $(,)?) => {
        $(
            impl ParseSynTokens for $type {
                fn parse_syn_tokens(tokens: proc_macro2::TokenStream) -> syn::Result<Self> {
                    syn::parse2(tokens)
                }
            }
        )+
    };
}

impl_parse_syn_tokens!(
    Arm,
    Block,
    Expr,
    Stmt,
    Type,
    syn::FnArg,
    syn::Item,
    syn::ItemConst,
    syn::ItemEnum,
    syn::ItemFn,
    syn::ItemImpl,
    syn::ItemMod,
    syn::ItemStruct,
    syn::ItemStatic,
    syn::ItemType,
    syn::ItemUse,
    syn::Variant,
);

impl ParseSynTokens for Pat {
    fn parse_syn_tokens(tokens: proc_macro2::TokenStream) -> syn::Result<Self> {
        Pat::parse_single.parse2(tokens)
    }
}

impl ParseSynTokens for syn::Attribute {
    fn parse_syn_tokens(tokens: proc_macro2::TokenStream) -> syn::Result<Self> {
        syn::Attribute::parse_outer
            .parse2(tokens)?
            .into_iter()
            .next()
            .ok_or_else(|| syn::Error::new(proc_macro2::Span::call_site(), "missing attribute"))
    }
}

pub(crate) fn parse_syn<T: ParseSynTokens>(tokens: proc_macro2::TokenStream) -> NifResult<T> {
    T::parse_syn_tokens(tokens).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn path_from_parts(parts: Vec<String>) -> NifResult<syn::Path> {
    if parts.is_empty() {
        return Err(rustler::Error::BadArg);
    }

    let source = parts
        .iter()
        .map(|part| path_part_source(part))
        .collect::<Vec<_>>()
        .join("::");

    syn::parse_str(&source).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn ident_from_part(part: &str) -> syn::Ident {
    if let Some(raw) = part.strip_prefix("r#") {
        return syn::Ident::new_raw(raw, proc_macro2::Span::call_site());
    }

    if rust_keyword(part) {
        syn::Ident::new_raw(part, proc_macro2::Span::call_site())
    } else {
        syn::Ident::new(part, proc_macro2::Span::call_site())
    }
}

fn path_part_source(part: &str) -> String {
    if rust_keyword(part) {
        format!("r#{part}")
    } else {
        part.to_string()
    }
}

fn rust_keyword(part: &str) -> bool {
    matches!(
        part,
        "as" | "async"
            | "await"
            | "break"
            | "const"
            | "continue"
            | "dyn"
            | "else"
            | "enum"
            | "extern"
            | "fn"
            | "for"
            | "if"
            | "impl"
            | "in"
            | "let"
            | "loop"
            | "match"
            | "mod"
            | "move"
            | "mut"
            | "pub"
            | "ref"
            | "return"
            | "static"
            | "struct"
            | "trait"
            | "type"
            | "unsafe"
            | "use"
            | "where"
            | "while"
    )
}

pub(crate) fn parse_expr(source: impl AsRef<str>) -> NifResult<Expr> {
    syn::parse_str(source.as_ref()).map_err(|_| rustler::Error::BadArg)
}
