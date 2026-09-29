use proc_macro2::{TokenStream, TokenTree};
use quote::ToTokens;
use rustler::{Encoder, Env, NifResult, Term};
use syn::visit::{self, Visit};
use syn::{
    Attribute, Expr, ExprCall, ExprLit, ExprMethodCall, ExprPath, Fields, FnArg, GenericArgument,
    ImplItem, Item, Lit, Macro, PathArguments, ReturnType, Type, TypeParamBound, UseTree,
    Visibility,
};

use crate::{atoms, template_error};

pub(crate) fn inspect_source<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    match syn::parse_file(&source) {
        Ok(file) => Ok((atoms::ok(), items(env, file.items)).encode(env)),
        Err(error) => Ok((atoms::error(), vec![template_error(error)]).encode(env)),
    }
}

pub(crate) fn atom_references<'a>(
    env: Env<'a>,
    source: String,
    module: String,
) -> NifResult<Term<'a>> {
    match syn::parse_file(&source) {
        Ok(file) => {
            let mut visitor = AtomReferenceVisitor {
                atoms: Vec::new(),
                module,
            };
            visitor.visit_file(&file);
            visitor.atoms.sort();
            visitor.atoms.dedup();
            Ok((atoms::ok(), visitor.atoms).encode(env))
        }
        Err(error) => Ok((atoms::error(), vec![template_error(error)]).encode(env)),
    }
}

pub(crate) fn method_references<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    match syn::parse_file(&source) {
        Ok(file) => {
            let mut visitor = MethodReferenceVisitor { calls: Vec::new() };
            visitor.visit_file(&file);
            visitor.calls.sort();
            visitor.calls.dedup();
            let methods = visitor
                .calls
                .into_iter()
                .map(|(_receiver, method)| method)
                .collect::<Vec<_>>();
            Ok((atoms::ok(), methods).encode(env))
        }
        Err(error) => Ok((atoms::error(), vec![template_error(error)]).encode(env)),
    }
}

pub(crate) fn method_calls<'a>(env: Env<'a>, source: String) -> NifResult<Term<'a>> {
    match syn::parse_file(&source) {
        Ok(file) => {
            let mut visitor = MethodReferenceVisitor { calls: Vec::new() };
            visitor.visit_file(&file);
            visitor.calls.sort();
            visitor.calls.dedup();
            Ok((atoms::ok(), visitor.calls).encode(env))
        }
        Err(error) => Ok((atoms::error(), vec![template_error(error)]).encode(env)),
    }
}

pub(crate) fn enum_variants<'a>(
    env: Env<'a>,
    source: String,
    enum_name: String,
) -> NifResult<Term<'a>> {
    match syn::parse_file(&source) {
        Ok(file) => {
            let variants = file.items.into_iter().find_map(|item| match item {
                Item::Enum(item) if item.ident == enum_name => Some(
                    item.variants
                        .into_iter()
                        .map(|variant| variant.ident.to_string())
                        .collect::<Vec<_>>(),
                ),
                _ => None,
            });

            match variants {
                Some(variants) => Ok((atoms::ok(), variants).encode(env)),
                None => Ok((atoms::error(), format!("enum {enum_name} not found")).encode(env)),
            }
        }
        Err(error) => Ok((atoms::error(), vec![template_error(error)]).encode(env)),
    }
}

struct AtomReferenceVisitor {
    atoms: Vec<String>,
    module: String,
}

struct MethodReferenceVisitor {
    calls: Vec<(String, String)>,
}

impl<'ast> Visit<'ast> for MethodReferenceVisitor {
    fn visit_expr_method_call(&mut self, node: &'ast ExprMethodCall) {
        self.calls.push((
            node.receiver.to_token_stream().to_string(),
            node.method.to_string(),
        ));
        visit::visit_expr_method_call(self, node);
    }
}

impl<'ast> Visit<'ast> for AtomReferenceVisitor {
    fn visit_expr_call(&mut self, node: &'ast ExprCall) {
        if let Expr::Path(ExprPath { path, .. }) = &*node.func {
            if path.segments.len() == 2
                && path.segments[0].ident == self.module.as_str()
                && matches!(path.segments[1].arguments, PathArguments::None)
            {
                self.atoms.push(path.segments[1].ident.to_string());
            }
        }

        visit::visit_expr_call(self, node);
    }

    fn visit_macro(&mut self, node: &'ast Macro) {
        collect_macro_atom_references(node.tokens.clone(), &self.module, &mut self.atoms);
        visit::visit_macro(self, node);
    }
}

fn collect_macro_atom_references(tokens: TokenStream, module_name: &str, atoms: &mut Vec<String>) {
    let trees = tokens.into_iter().collect::<Vec<_>>();

    for window in trees.windows(4) {
        if let [TokenTree::Ident(module), TokenTree::Punct(first), TokenTree::Punct(second), TokenTree::Ident(name)] =
            window
        {
            if module == module_name && first.as_char() == ':' && second.as_char() == ':' {
                atoms.push(name.to_string());
            }
        }
    }

    for tree in trees {
        if let TokenTree::Group(group) = tree {
            collect_macro_atom_references(group.stream(), module_name, atoms);
        }
    }
}

fn items<'a>(env: Env<'a>, items: Vec<Item>) -> Vec<Term<'a>> {
    items_with_module(env, items, Vec::new())
}

fn items_with_module<'a>(
    env: Env<'a>,
    items: Vec<Item>,
    module_path: Vec<String>,
) -> Vec<Term<'a>> {
    items
        .into_iter()
        .flat_map(|item| item_terms(env, item, module_path.clone()))
        .collect()
}

fn item_terms<'a>(env: Env<'a>, item: Item, module_path: Vec<String>) -> Vec<Term<'a>> {
    match item {
        Item::Enum(item) => vec![(
            "enum",
            item.ident.to_string(),
            visibility(&item.vis),
            line(item.ident.span()),
            docs(&item.attrs),
            item.variants
                .iter()
                .map(|variant| variant.ident.to_string())
                .collect::<Vec<_>>(),
            (
                item.variants
                    .into_iter()
                    .map(|variant| variant_shape(env, variant))
                    .collect::<Vec<_>>(),
                generics(&item.generics),
            ),
        )
            .encode(env)],
        Item::Struct(item) => vec![(
            "struct",
            item.ident.to_string(),
            visibility(&item.vis),
            line(item.ident.span()),
            docs(&item.attrs),
            fields(env, item.fields),
            generics(&item.generics),
        )
            .encode(env)],
        Item::Fn(item) => vec![(
            "function",
            item.sig.ident.to_string(),
            (module_path, visibility(&item.vis)),
            (
                line(item.sig.ident.span()),
                item.sig.to_token_stream().to_string(),
                item.sig
                    .generics
                    .lifetimes()
                    .map(|param| param.lifetime.ident.to_string())
                    .collect::<Vec<_>>(),
            ),
            docs(&item.attrs),
            item.sig
                .inputs
                .into_iter()
                .map(|arg| function_arg(env, arg))
                .collect::<Vec<_>>(),
            return_type(env, item.sig.output),
        )
            .encode(env)],
        Item::Impl(item) => vec![(
            "impl",
            type_string(&item.self_ty),
            type_metadata(env, &item.self_ty),
            item.trait_
                .map(|(_bang, path, _for)| path.to_token_stream().to_string()),
            (line(item.impl_token.span), type_parameters(&item.generics)),
            docs(&item.attrs),
            item.items
                .into_iter()
                .filter_map(|method| impl_method_term(env, method, &item.generics))
                .collect::<Vec<_>>(),
        )
            .encode(env)],
        Item::Use(item) => use_aliases(&item.tree)
            .into_iter()
            .map(|(path, segments, alias, glob)| {
                (
                    "use",
                    path,
                    segments,
                    alias,
                    glob,
                    (
                        module_path.clone(),
                        visibility(&item.vis),
                        line(item.use_token.span),
                    ),
                    docs(&item.attrs),
                )
                    .encode(env)
            })
            .collect(),
        Item::Static(item) => vec![(
            "static",
            item.ident.to_string(),
            visibility(&item.vis),
            line(item.ident.span()),
            docs(&item.attrs),
            (
                type_string(&item.ty),
                type_metadata(env, &item.ty),
                matches!(item.mutability, syn::StaticMutability::Mut(_)),
            ),
        )
            .encode(env)],
        Item::Type(item) => vec![(
            "type_alias",
            item.ident.to_string(),
            visibility(&item.vis),
            (module_path, line(item.ident.span())),
            docs(&item.attrs),
            (type_string(&item.ty), type_parameters(&item.generics)),
            type_metadata(env, &item.ty),
        )
            .encode(env)],
        Item::Mod(item) => {
            if let Some((_brace, items)) = item.content {
                let mut nested_path = module_path;
                nested_path.push(item.ident.to_string());
                items_with_module(env, items, nested_path)
            } else {
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

fn use_aliases(tree: &UseTree) -> Vec<(String, Vec<String>, Option<String>, bool)> {
    match tree {
        UseTree::Group(group) => group.items.iter().flat_map(use_aliases).collect(),
        UseTree::Path(path) => use_aliases(&path.tree)
            .into_iter()
            .map(|(_, mut segments, alias, glob)| {
                segments.insert(0, path.ident.to_string());
                (segments.join("::"), segments, alias, glob)
            })
            .collect(),
        _ => use_alias(tree).into_iter().collect(),
    }
}

fn use_alias(tree: &UseTree) -> Option<(String, Vec<String>, Option<String>, bool)> {
    fn walk(
        tree: &UseTree,
        prefix: Vec<String>,
    ) -> Option<(String, Vec<String>, Option<String>, bool)> {
        match tree {
            UseTree::Path(path) => {
                let mut prefix = prefix;
                prefix.push(path.ident.to_string());
                walk(&path.tree, prefix)
            }
            UseTree::Rename(rename) => {
                let mut path = prefix;
                path.push(rename.ident.to_string());
                Some((
                    path.join("::"),
                    path,
                    Some(rename.rename.to_string()),
                    false,
                ))
            }
            UseTree::Name(name) => {
                let mut path = prefix;
                path.push(name.ident.to_string());
                Some((path.join("::"), path, Some(name.ident.to_string()), false))
            }
            UseTree::Glob(_glob) => Some((prefix.join("::"), prefix, None, true)),
            _ => None,
        }
    }

    walk(tree, Vec::new())
}

fn type_parameters(generics: &syn::Generics) -> Vec<String> {
    generics
        .type_params()
        .map(|param| param.ident.to_string())
        .collect()
}

fn impl_method_term<'a>(
    env: Env<'a>,
    item: ImplItem,
    generics: &syn::Generics,
) -> Option<Term<'a>> {
    match item {
        ImplItem::Fn(item) => Some(
            (
                "method",
                item.sig.ident.to_string(),
                visibility(&item.vis),
                (
                    line(item.sig.ident.span()),
                    item.sig.to_token_stream().to_string(),
                    [
                        type_parameters(generics),
                        type_parameters(&item.sig.generics),
                    ]
                    .concat(),
                ),
                docs(&item.attrs),
                item.sig
                    .inputs
                    .into_iter()
                    .map(|arg| function_arg(env, arg))
                    .collect::<Vec<_>>(),
                return_type(env, item.sig.output),
            )
                .encode(env),
        ),
        _ => None,
    }
}

fn line(span: proc_macro2::Span) -> usize {
    span.start().line
}

fn variant_shape<'a>(env: Env<'a>, variant: syn::Variant) -> Term<'a> {
    let kind = match &variant.fields {
        Fields::Named(_) => "named",
        Fields::Unnamed(_) => "tuple",
        Fields::Unit => "unit",
    };
    (
        variant.ident.to_string(),
        kind,
        fields(env, variant.fields),
        docs(&variant.attrs),
    )
        .encode(env)
}

fn generics(generics: &syn::Generics) -> (Vec<String>, Vec<String>) {
    (
        generics
            .lifetimes()
            .map(|param| param.lifetime.ident.to_string())
            .collect(),
        type_parameters(generics),
    )
}

fn fields<'a>(env: Env<'a>, fields: Fields) -> Vec<(Option<String>, String, Term<'a>)> {
    fields
        .into_iter()
        .map(|field| {
            let ty = field.ty;
            (
                field.ident.map(|ident| ident.to_string()),
                type_string(&ty),
                type_metadata(env, &ty),
            )
        })
        .collect()
}

fn function_arg<'a>(env: Env<'a>, arg: FnArg) -> (Option<String>, String, Term<'a>) {
    match arg {
        FnArg::Receiver(receiver) => (
            Some("self".to_string()),
            receiver.to_token_stream().to_string(),
            receiver_type_metadata(env, &receiver),
        ),
        FnArg::Typed(arg) => {
            let ty = *arg.ty;
            (
                pat_name(*arg.pat),
                type_string(&ty),
                type_metadata(env, &ty),
            )
        }
    }
}

fn pat_name(pat: syn::Pat) -> Option<String> {
    match pat {
        syn::Pat::Ident(ident) => Some(ident.ident.to_string()),
        _ => None,
    }
}

fn return_type<'a>(env: Env<'a>, output: ReturnType) -> Option<(String, Term<'a>)> {
    match output {
        ReturnType::Default => None,
        ReturnType::Type(_, ty) => Some((type_string(&ty), type_metadata(env, &ty))),
    }
}

fn type_string(ty: &Type) -> String {
    ty.to_token_stream().to_string()
}

fn receiver_type_metadata<'a>(env: Env<'a>, receiver: &syn::Receiver) -> Term<'a> {
    let self_term = ("self", "Self").encode(env);

    if let Some((_and, lifetime)) = &receiver.reference {
        (
            "ref",
            receiver.to_token_stream().to_string(),
            receiver.mutability.is_some(),
            lifetime.as_ref().map(ToString::to_string),
            self_term,
        )
            .encode(env)
    } else {
        self_term
    }
}

fn type_metadata<'a>(env: Env<'a>, ty: &Type) -> Term<'a> {
    let code = type_string(ty);

    match ty {
        Type::Path(path) if path.qself.is_none() && path.path.is_ident("Self") => {
            ("self", code).encode(env)
        }
        Type::Path(path) if path.qself.is_none() => path_type_metadata(env, code, &path.path),
        Type::Reference(reference) => (
            "ref",
            code,
            reference.mutability.is_some(),
            reference.lifetime.as_ref().map(ToString::to_string),
            type_metadata(env, &reference.elem),
        )
            .encode(env),
        Type::Tuple(tuple) => (
            "tuple",
            code,
            tuple
                .elems
                .iter()
                .map(|elem| type_metadata(env, elem))
                .collect::<Vec<_>>(),
        )
            .encode(env),
        Type::ImplTrait(impl_trait) => (
            "impl_trait",
            code,
            impl_trait
                .bounds
                .iter()
                .filter_map(|bound| trait_bound_metadata(env, bound))
                .collect::<Vec<_>>(),
            impl_trait
                .bounds
                .iter()
                .map(|bound| bound_metadata(env, bound))
                .collect::<Vec<_>>(),
        )
            .encode(env),
        Type::Slice(slice) => ("slice", code, type_metadata(env, &slice.elem)).encode(env),
        Type::Array(array) => (
            "array",
            code,
            type_metadata(env, &array.elem),
            array.len.to_token_stream().to_string(),
        )
            .encode(env),
        Type::BareFn(function) => (
            "fn",
            code,
            (
                function
                    .lifetimes
                    .as_ref()
                    .map(|bound| {
                        bound
                            .lifetimes
                            .iter()
                            .map(|param| param.to_token_stream().to_string())
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default(),
                function.unsafety.is_some(),
                function.abi.is_some(),
                function
                    .abi
                    .as_ref()
                    .and_then(|abi| abi.name.as_ref().map(|name| name.value())),
            ),
            (
                function
                    .inputs
                    .iter()
                    .map(|arg| type_metadata(env, &arg.ty))
                    .collect::<Vec<_>>(),
                function
                    .inputs
                    .iter()
                    .map(|arg| arg.name.as_ref().map(|(name, _colon)| name.to_string()))
                    .collect::<Vec<_>>(),
                function.variadic.is_some(),
                function
                    .variadic
                    .as_ref()
                    .and_then(|arg| arg.name.as_ref().map(|(name, _colon)| name.to_string())),
            ),
            match &function.output {
                ReturnType::Default => None,
                ReturnType::Type(_arrow, ty) => Some(type_metadata(env, ty)),
            },
        )
            .encode(env),
        _ => ("raw", code).encode(env),
    }
}

fn path_type_metadata<'a>(env: Env<'a>, code: String, path: &syn::Path) -> Term<'a> {
    let segments = path
        .segments
        .iter()
        .map(|segment| segment.ident.to_string())
        .collect::<Vec<_>>();

    let (args, assoc, generic_args) = path
        .segments
        .last()
        .map(|segment| generic_args(env, &segment.arguments))
        .unwrap_or_default();

    if let Some(syn::PathSegment {
        arguments: PathArguments::Parenthesized(arguments),
        ..
    }) = path.segments.last()
    {
        let inputs = arguments
            .inputs
            .iter()
            .map(|ty| type_metadata(env, ty))
            .collect::<Vec<_>>();
        let output = match &arguments.output {
            syn::ReturnType::Default => None,
            syn::ReturnType::Type(_, ty) => Some(type_metadata(env, ty)),
        };
        return ("callable_path", code, segments, inputs, output).encode(env);
    }

    let name = segments.last().cloned().unwrap_or_else(|| code.clone());

    match name.as_str() {
        "Option" if args.len() == 1 => ("option", code, args[0]).encode(env),
        "Result" if args.len() == 2 => ("result", code, args[0], args[1]).encode(env),
        _ => ("path", code, segments, args, assoc, generic_args).encode(env),
    }
}

fn trait_bound_metadata<'a>(env: Env<'a>, bound: &TypeParamBound) -> Option<Term<'a>> {
    match bound {
        TypeParamBound::Trait(trait_bound) => Some(path_type_metadata(
            env,
            trait_bound.path.to_token_stream().to_string(),
            &trait_bound.path,
        )),
        _ => None,
    }
}

fn bound_metadata<'a>(env: Env<'a>, bound: &TypeParamBound) -> Term<'a> {
    match bound {
        TypeParamBound::Trait(trait_bound) => (
            "trait",
            trait_bound.to_token_stream().to_string(),
            match trait_bound.modifier {
                syn::TraitBoundModifier::None => "none",
                syn::TraitBoundModifier::Maybe(_) => "maybe",
            },
            trait_bound
                .lifetimes
                .as_ref()
                .map(|bound| {
                    bound
                        .lifetimes
                        .iter()
                        .map(|param| param.to_token_stream().to_string())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default(),
            path_type_metadata(
                env,
                trait_bound.path.to_token_stream().to_string(),
                &trait_bound.path,
            ),
        )
            .encode(env),
        TypeParamBound::Lifetime(lifetime) => {
            ("lifetime", lifetime.to_token_stream().to_string()).encode(env)
        }
        TypeParamBound::PreciseCapture(capture) => {
            ("precise_capture", capture.to_token_stream().to_string()).encode(env)
        }
        TypeParamBound::Verbatim(tokens) => ("raw", tokens.to_string()).encode(env),
        _ => ("raw", bound.to_token_stream().to_string()).encode(env),
    }
}

fn generic_args<'a>(
    env: Env<'a>,
    arguments: &PathArguments,
) -> (Vec<Term<'a>>, Vec<Term<'a>>, Vec<Term<'a>>) {
    match arguments {
        PathArguments::AngleBracketed(args) => {
            let mut positional = Vec::new();
            let mut associated = Vec::new();
            let mut ordered = Vec::new();

            for arg in &args.args {
                match arg {
                    GenericArgument::Lifetime(lifetime) => ordered
                        .push(("lifetime", lifetime.to_token_stream().to_string()).encode(env)),
                    GenericArgument::Type(ty) => {
                        let metadata = type_metadata(env, ty);
                        positional.push(metadata);
                        ordered.push(("type", metadata).encode(env));
                    }
                    GenericArgument::Const(expr) => {
                        ordered.push(("const", expr.to_token_stream().to_string()).encode(env));
                    }
                    GenericArgument::AssocType(assoc) => {
                        let metadata = type_metadata(env, &assoc.ty);
                        associated.push((assoc.ident.to_string(), metadata).encode(env));
                        ordered.push(("assoc_type", assoc.ident.to_string(), metadata).encode(env));
                    }
                    GenericArgument::AssocConst(assoc) => ordered.push(
                        (
                            "assoc_const",
                            assoc.ident.to_string(),
                            assoc.value.to_token_stream().to_string(),
                        )
                            .encode(env),
                    ),
                    GenericArgument::Constraint(constraint) => ordered.push(
                        (
                            "constraint",
                            constraint.ident.to_string(),
                            constraint.to_token_stream().to_string(),
                        )
                            .encode(env),
                    ),
                    _ => {}
                }
            }

            (positional, associated, ordered)
        }
        _ => (Vec::new(), Vec::new(), Vec::new()),
    }
}

fn docs(attrs: &[Attribute]) -> Vec<String> {
    attrs
        .iter()
        .filter_map(|attr| {
            if !attr.path().is_ident("doc") {
                return None;
            }

            match &attr.meta {
                syn::Meta::NameValue(name_value) => match &name_value.value {
                    Expr::Lit(ExprLit {
                        lit: Lit::Str(value),
                        ..
                    }) => Some(value.value().trim().to_string()),
                    _ => None,
                },
                _ => None,
            }
        })
        .collect()
}

fn visibility(vis: &Visibility) -> &'static str {
    match vis {
        Visibility::Public(_) => "public",
        _ => "private",
    }
}
