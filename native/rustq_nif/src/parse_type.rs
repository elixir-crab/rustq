use quote::{quote, ToTokens};
use rustler::NifResult;
use syn::Type;

use crate::{parse_syn, path_from_parts};

pub(crate) fn parse_type_path_with_generics(
    path: Vec<String>,
    lifetimes: Vec<String>,
    generics: Vec<Type>,
) -> NifResult<Type> {
    let path = path_from_parts(path)?;
    let lifetimes = lifetimes
        .into_iter()
        .map(|value| syn::Lifetime::new(&format!("'{}", value), proc_macro2::Span::call_site()))
        .collect::<Vec<_>>();

    if lifetimes.is_empty() && generics.is_empty() {
        parse_syn(quote!(#path))
    } else {
        parse_syn(quote!(#path < #(#lifetimes,)* #(#generics),* >))
    }
}

pub(crate) fn parse_type_unit(_term: rustler::Term) -> NifResult<Type> {
    parse_syn(quote!(()))
}

pub(crate) fn parse_type_raw(source: String) -> NifResult<Type> {
    syn::parse_str::<Type>(&source).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn parse_type_slice(inner: Type) -> NifResult<Type> {
    parse_syn(quote!([#inner]))
}

pub(crate) fn parse_type_tuple(items: Vec<Type>) -> NifResult<Type> {
    if items.is_empty() {
        Err(rustler::Error::BadArg)
    } else {
        parse_syn(quote!((#(#items,)*)))
    }
}

pub(crate) fn parse_callable_impl(
    callable: Option<Type>,
    kind: String,
    traits: Vec<Type>,
    lifetime: Option<String>,
    bounds: Vec<String>,
) -> NifResult<Type> {
    let Some(Type::BareFn(callable)) = callable else {
        return parse_type_impl_trait(bounds);
    };
    let name = match kind.as_str() {
        "fn" => quote!(Fn),
        "fn_mut" => quote!(FnMut),
        "fn_once" => quote!(FnOnce),
        _ => return Err(rustler::Error::BadArg),
    };
    let args = callable.inputs.iter().map(|arg| &arg.ty);
    let output = &callable.output;
    let lifetime = lifetime
        .map(|name| syn::parse_str::<syn::Lifetime>(&format!("'{name}")))
        .transpose()
        .map_err(|_| rustler::Error::BadArg)?;
    let lifetime = lifetime.map(|value| quote!(+ #value));
    parse_syn(quote!(impl #name(#(#args),*) #output #(+ #traits)* #lifetime))
}

pub(crate) fn parse_type_impl_trait(bounds: Vec<String>) -> NifResult<Type> {
    if bounds.is_empty() {
        return Err(rustler::Error::BadArg);
    }

    syn::parse_str::<Type>(&format!("impl {}", bounds.join(" + ")))
        .map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn parse_type_bare_fn(
    args: Vec<Type>,
    returns: Option<Type>,
    lifetimes: Vec<String>,
    unsafe_: bool,
    external: bool,
    abi: Option<String>,
    variadic: bool,
) -> NifResult<Type> {
    let lifetimes = if lifetimes.is_empty() {
        String::new()
    } else {
        format!(
            "for<{}> ",
            lifetimes
                .into_iter()
                .map(|lifetime| {
                    if lifetime.starts_with('\'') {
                        lifetime
                    } else {
                        format!("'{lifetime}")
                    }
                })
                .collect::<Vec<_>>()
                .join(", ")
        )
    };
    let unsafe_ = if unsafe_ { "unsafe " } else { "" };
    let external = match (external, abi) {
        (true, Some(abi)) => format!("extern {abi:?} "),
        (true, None) => "extern ".to_string(),
        (false, _) => String::new(),
    };
    let mut args = args
        .into_iter()
        .map(|arg| arg.to_token_stream().to_string())
        .collect::<Vec<_>>();

    if variadic {
        args.push("...".to_string());
    }

    let returns = returns
        .map(|returns| format!(" -> {}", returns.to_token_stream()))
        .unwrap_or_default();
    let source = format!(
        "{lifetimes}{unsafe_}{external}fn({}){returns}",
        args.join(", ")
    );

    syn::parse_str::<Type>(&source).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn parse_type_array(inner: Type, size: rustler::Term) -> NifResult<Type> {
    let size_source = if let Ok(size) = size.decode::<u64>() {
        size.to_string()
    } else {
        size.decode::<String>()?
    };

    let size: syn::Expr = syn::parse_str(&size_source).map_err(|_| rustler::Error::BadArg)?;
    parse_syn(quote!([#inner; #size]))
}

pub(crate) fn parse_type_ref(
    inner: Type,
    mutable: bool,
    lifetime: Option<String>,
) -> NifResult<Type> {
    match (mutable, lifetime) {
        (true, Some(lifetime)) => {
            let lifetime =
                syn::Lifetime::new(&format!("'{}", lifetime), proc_macro2::Span::call_site());
            parse_syn(quote!(& #lifetime mut #inner))
        }
        (true, None) => parse_syn(quote!(& mut #inner)),
        (false, Some(lifetime)) => {
            let lifetime =
                syn::Lifetime::new(&format!("'{}", lifetime), proc_macro2::Span::call_site());
            parse_syn(quote!(& #lifetime #inner))
        }
        (false, None) => parse_syn(quote!(& #inner)),
    }
}

pub(crate) fn parse_type_generic(path: &str, args: Vec<Type>) -> NifResult<Type> {
    let path: syn::Path = syn::parse_str(path).map_err(|_| rustler::Error::BadArg)?;
    parse_syn(quote!(#path < #(#args),* >))
}
