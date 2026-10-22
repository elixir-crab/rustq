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

/// Parses generated tokens, keeping syn's message for a node that does not form valid Rust.
pub(crate) fn parse_syn<T: ParseSynTokens>(tokens: proc_macro2::TokenStream) -> NifResult<T> {
    T::parse_syn_tokens(tokens).map_err(|error| rustler::Error::Term(Box::new(error.to_string())))
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

/// The identifier Rust writes for `part`: itself, or raw for a keyword. `self`, `super`, and
/// the like are kept for the positions that take them; anything else that is no identifier,
/// such as a dotted module name, is an error rather than a panic.
pub(crate) fn ident_from_part(part: &str) -> NifResult<syn::Ident> {
    use syn::ext::IdentExt;
    use syn::parse::Parser;

    let name = rust_name(part);

    let parsed = if part.starts_with("r#") {
        syn::parse_str::<syn::Ident>(part)
    } else if rust_keyword(name) {
        syn::parse_str::<syn::Ident>(&format!("r#{name}"))
    } else {
        syn::Ident::parse_any.parse_str(name)
    };

    parsed.map_err(|_error| {
        rustler::Error::Term(Box::new(format!("`{part}` cannot be a Rust identifier")))
    })
}

/// An Elixir predicate's name without its `?`, as Rust names predicates.
fn rust_name(part: &str) -> &str {
    part.strip_suffix('?').unwrap_or(part)
}

fn path_part_source(part: &str) -> String {
    let part = rust_name(part);

    if rust_keyword(part) {
        format!("r#{part}")
    } else {
        part.to_string()
    }
}

/// How Rust writes `name` where `context` expects it: as itself when syn reads it there, as an
/// identifier (`"name"`), a path segment (`"segment"`, where `self` or `crate` fit), or an
/// expression (`"expr"`, where `self` fits); as `r#name` for another keyword; otherwise it is
/// an error.
pub(crate) fn identifier_source(name: &str, context: &str) -> NifResult<String> {
    let name = rust_name(name);

    let fits = match context {
        "segment" => syn::parse_str::<syn::PathSegment>(name).is_ok(),
        "expr" => syn::parse_str::<syn::Expr>(name).is_ok(),
        _ => syn::parse_str::<syn::Ident>(name).is_ok(),
    };

    if fits {
        Ok(name.to_string())
    } else if rust_keyword(name) {
        Ok(format!("r#{name}"))
    } else {
        Err(rustler::Error::Term(Box::new(format!(
            "`{name}` cannot be a Rust identifier"
        ))))
    }
}

/// Whether `part` is a Rust keyword, which Rust writes as a raw identifier: syn reads it as an
/// identifier only with the `r#` prefix. `self`, `Self`, `super`, and `crate` are neither.
fn rust_keyword(part: &str) -> bool {
    syn::parse_str::<syn::Ident>(part).is_err()
        && syn::parse_str::<syn::Ident>(&format!("r#{part}")).is_ok()
}

pub(crate) fn parse_expr(source: impl AsRef<str>) -> NifResult<Expr> {
    syn::parse_str(source.as_ref()).map_err(|_| rustler::Error::BadArg)
}
