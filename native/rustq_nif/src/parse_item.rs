use quote::{format_ident, quote, ToTokens};
use rustler::{NifResult, Term};
use syn::{punctuated::Punctuated, token, Expr, Field, FnArg, Item, Stmt, Type};

use crate::{parse_syn, path_from_parts};

pub(crate) fn parse_item_use(tree: String) -> NifResult<syn::ItemUse> {
    syn::parse_str(&format!("use {tree};")).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn parse_item_use_path(parts: Vec<String>) -> NifResult<syn::ItemUse> {
    let path = path_from_parts(parts)?;
    parse_syn(quote!(use #path;))
}

pub(crate) fn parse_item_use_group(
    base: Vec<String>,
    names: Vec<String>,
) -> NifResult<syn::ItemUse> {
    let base = path_from_parts(base)?;
    let names = names
        .into_iter()
        .map(|name| format_ident!("{}", name))
        .collect::<Vec<_>>();

    parse_syn(quote!(use #base::{#(#names),*};))
}

pub(crate) fn parse_item_module(
    name: syn::Ident,
    vis: syn::Visibility,
    items: Vec<Item>,
) -> NifResult<syn::ItemMod> {
    parse_syn(quote!(#vis mod #name { #(#items)* }))
}

pub(crate) fn parse_item_impl(
    target: Type,
    trait_path: Option<Type>,
    items: Vec<Item>,
    attrs: Vec<syn::Attribute>,
    lifetimes: Vec<String>,
) -> NifResult<syn::ItemImpl> {
    let item_tokens = items
        .into_iter()
        .map(|item| match item {
            Item::Fn(function) => quote!(#function),
            other => quote!(#other),
        })
        .collect::<Vec<_>>();

    let lifetime_tokens = lifetimes
        .into_iter()
        .map(|name| syn::Lifetime::new(&format!("'{}", name), proc_macro2::Span::call_site()))
        .collect::<Vec<_>>();

    match (trait_path, lifetime_tokens.is_empty()) {
        (Some(trait_path), true) => {
            parse_syn(quote!(#(#attrs)* impl #trait_path for #target { #(#item_tokens)* }))
        }
        (Some(trait_path), false) => parse_syn(
            quote!(#(#attrs)* impl<#(#lifetime_tokens),*> #trait_path for #target { #(#item_tokens)* }),
        ),
        (None, true) => parse_syn(quote!(#(#attrs)* impl #target { #(#item_tokens)* })),
        (None, false) => {
            parse_syn(quote!(#(#attrs)* impl<#(#lifetime_tokens),*> #target { #(#item_tokens)* }))
        }
    }
}

pub(crate) fn parse_item_const(
    name: syn::Ident,
    ty: Type,
    expr: Expr,
    vis: syn::Visibility,
) -> NifResult<syn::ItemConst> {
    parse_syn(quote!(#vis const #name: #ty = #expr;))
}

pub(crate) fn parse_item_static(
    name: syn::Ident,
    ty: Type,
    expr: Expr,
    mutable: bool,
    vis: syn::Visibility,
) -> NifResult<syn::ItemStatic> {
    if mutable {
        parse_syn(quote!(#vis static mut #name: #ty = #expr;))
    } else {
        parse_syn(quote!(#vis static #name: #ty = #expr;))
    }
}

pub(crate) fn parse_item_type(
    name: syn::Ident,
    ty: Type,
    vis: syn::Visibility,
) -> NifResult<syn::ItemType> {
    parse_syn(quote!(#vis type #name = #ty;))
}

pub(crate) fn parse_macro_item(source: String) -> NifResult<Item> {
    syn::parse_str(&source).map_err(|_| rustler::Error::BadArg)
}

pub(crate) fn parse_macro_rules_term(term: Term) -> NifResult<Item> {
    let name = crate::generated_ast::atom_key(term, "name")?;
    let attrs = crate::decode_attribute_list(crate::generated_ast::required_field(term, "attrs")?)?;
    let rules = crate::generated_ast::required_field(term, "rules")?
        .decode::<Vec<Term>>()?
        .into_iter()
        .map(macro_rule_source)
        .collect::<NifResult<Vec<_>>>()?;

    let attrs = quote!(#(#attrs)*).to_string();
    parse_macro_item(format!(
        "{attrs} macro_rules! {name} {{\n{}\n}}",
        rules.join("\n")
    ))
}

fn macro_rule_source(term: Term) -> NifResult<String> {
    crate::generated_ast::expect_struct(term, crate::generated_ast::ast_modules::MACRO_RULE)?;
    let pattern = macro_token_list_source(crate::generated_ast::required_field(term, "pattern")?)?;
    let expansion =
        macro_token_list_source(crate::generated_ast::required_field(term, "expansion")?)?;
    Ok(format!("({pattern}) => {{\n{expansion}\n}};"))
}

fn macro_token_list_source(term: Term) -> NifResult<String> {
    term.decode::<Vec<Term>>()?
        .into_iter()
        .map(macro_token_source)
        .collect::<NifResult<Vec<_>>>()
        .map(|tokens| tokens.join(""))
}

fn macro_token_source(term: Term) -> NifResult<String> {
    if let Ok(struct_name) = crate::generated_ast::struct_name(term) {
        return match struct_name.as_str() {
            crate::generated_ast::ast_modules::MACRO_VAR => macro_var_source(term),
            crate::generated_ast::ast_modules::MACRO_CAPTURE => macro_capture_source(term),
            crate::generated_ast::ast_modules::MACRO_REPEAT => macro_repeat_source(term),
            crate::generated_ast::ast_modules::LITERAL
            | crate::generated_ast::ast_modules::PATH => {
                Ok(crate::generated_ast::decode_ast_expr(term)?
                    .to_token_stream()
                    .to_string())
            }
            _ => Err(rustler::Error::BadArg),
        };
    }

    crate::atom_or_string(term)
}

fn macro_var_source(term: Term) -> NifResult<String> {
    let name = crate::generated_ast::atom_key(term, "name")?;
    let fragment = crate::generated_ast::atom_key(term, "fragment")?;
    Ok(format!("${name}:{fragment}"))
}

fn macro_capture_source(term: Term) -> NifResult<String> {
    let name = crate::generated_ast::atom_key(term, "name")?;
    Ok(format!("${name}"))
}

fn macro_repeat_source(term: Term) -> NifResult<String> {
    crate::generated_ast::expect_struct(term, crate::generated_ast::ast_modules::MACRO_REPEAT)?;
    let tokens = macro_token_list_source(crate::generated_ast::required_field(term, "tokens")?)?;
    let separator_term = crate::generated_ast::required_field(term, "separator")?;
    let separator = if crate::generated_ast::is_nil(separator_term)? {
        String::new()
    } else {
        separator_term.decode::<String>()?
    };
    let operator = crate::generated_ast::atom_key(term, "operator")?;
    Ok(format!("$({tokens}){separator}{operator}"))
}

pub(crate) struct MacroItemArg {
    name: proc_macro2::Ident,
    value: Option<String>,
}

impl ToTokens for MacroItemArg {
    fn to_tokens(&self, tokens: &mut proc_macro2::TokenStream) {
        let name = &self.name;

        if let Some(value) = &self.value {
            tokens.extend(quote!(#name = #value));
        } else {
            tokens.extend(quote!(#name));
        }
    }
}

pub(crate) fn decode_macro_item_arg_list(term: Term) -> NifResult<Vec<MacroItemArg>> {
    term.decode::<Vec<Term>>()?
        .into_iter()
        .map(decode_macro_item_arg)
        .collect()
}

fn decode_macro_item_arg(term: Term) -> NifResult<MacroItemArg> {
    if let Ok((name, value)) = term.decode::<(Term, String)>() {
        return Ok(MacroItemArg {
            name: format_ident!("{}", crate::atom_or_string(name)?),
            value: Some(value),
        });
    }

    Ok(MacroItemArg {
        name: format_ident!("{}", crate::atom_or_string(term)?),
        value: None,
    })
}

pub(crate) fn parse_macro_item_call(path: syn::Path, args: Vec<MacroItemArg>) -> NifResult<Item> {
    parse_syn(quote!(#path! { #(#args),* }))
}

pub(crate) fn parse_macro_item_token_call(path: syn::Path, tokens: Term) -> NifResult<Item> {
    let path = path.to_token_stream().to_string();
    let tokens = macro_token_list_source(tokens)?;
    parse_macro_item(format!("{path}! {{ {tokens} }}"))
}

pub(crate) fn parse_item_function_args(
    name: syn::Ident,
    vis: syn::Visibility,
    args: Vec<FnArg>,
    returns: Type,
    lifetimes: Vec<String>,
    stmts: Vec<Stmt>,
    attrs: Vec<syn::Attribute>,
) -> NifResult<syn::ItemFn> {
    let mut generics = syn::Generics::default();

    for lifetime in lifetimes {
        let lifetime =
            syn::Lifetime::new(&format!("'{}", lifetime), proc_macro2::Span::call_site());
        generics
            .params
            .push(syn::GenericParam::Lifetime(syn::LifetimeParam::new(
                lifetime,
            )));
    }

    Ok(syn::ItemFn {
        attrs,
        vis,
        sig: syn::Signature {
            constness: None,
            asyncness: None,
            unsafety: None,
            abi: None,
            fn_token: token::Fn::default(),
            ident: name,
            generics,
            paren_token: token::Paren::default(),
            inputs: Punctuated::from_iter(args),
            variadic: None,
            output: syn::ReturnType::Type(token::RArrow::default(), Box::new(returns)),
        },
        block: Box::new(syn::Block {
            brace_token: token::Brace::default(),
            stmts,
        }),
    })
}

pub(crate) fn parse_item_struct(
    name: syn::Ident,
    vis: syn::Visibility,
    derive: Vec<syn::Attribute>,
    lifetimes: Vec<String>,
    fields: Vec<Field>,
    attrs: Vec<syn::Attribute>,
) -> NifResult<syn::ItemStruct> {
    let lifetimes = lifetimes
        .into_iter()
        .map(|value| syn::Lifetime::new(&format!("'{}", value), proc_macro2::Span::call_site()))
        .collect::<Vec<_>>();

    let generics = if lifetimes.is_empty() {
        quote!()
    } else {
        quote!(<#(#lifetimes),*>)
    };

    parse_syn(quote!(#(#derive)* #(#attrs)* #vis struct #name #generics { #(#fields,)* }))
}

pub(crate) fn parse_function_arg(name: syn::Ident, ty: Type, mutable: bool) -> NifResult<FnArg> {
    if mutable {
        parse_syn(quote!(mut #name: #ty))
    } else {
        parse_syn(quote!(#name: #ty))
    }
}

pub(crate) fn parse_function_receiver(mutable: bool) -> NifResult<FnArg> {
    if mutable {
        parse_syn(quote!(&mut self))
    } else {
        parse_syn(quote!(&self))
    }
}

pub(crate) fn parse_struct_field(
    name: syn::Ident,
    ty: Type,
    vis: syn::Visibility,
) -> NifResult<Field> {
    let item: syn::ItemStruct = parse_syn(quote!(struct __RustQ { #vis #name: #ty, }))?;
    item.fields.into_iter().next().ok_or(rustler::Error::BadArg)
}

pub(crate) fn parse_item_enum(
    name: syn::Ident,
    vis: syn::Visibility,
    derive: Vec<syn::Attribute>,
    variants: Vec<syn::Variant>,
    attrs: Vec<syn::Attribute>,
) -> NifResult<syn::ItemEnum> {
    parse_syn(quote!(#(#derive)* #(#attrs)* #vis enum #name { #(#variants),* }))
}

pub(crate) fn parse_enum_variant(name: syn::Ident, tuple: Vec<Type>) -> NifResult<syn::Variant> {
    if tuple.is_empty() {
        parse_syn(quote!(#name))
    } else {
        parse_syn(quote!(#name(#(#tuple),*)))
    }
}
