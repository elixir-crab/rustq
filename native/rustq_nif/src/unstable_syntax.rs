//! Unstable Rust syntax that says nothing about an item's signature, rewritten token by token
//! into the stable syntax syn parses. The Rust standard library's source uses it throughout.

use proc_macro2::{Delimiter, Group, Spacing, TokenStream, TokenTree};

/// Parses a file that may use unstable syntax: `[const]` and `~const` bounds, `const` traits
/// and impls, `final` trait methods, and restricted `impl(...)` visibility.
pub(crate) fn parse_file(source: &str) -> syn::Result<syn::File> {
    let tokens: TokenStream = source
        .parse()
        .map_err(|error: proc_macro2::LexError| syn::Error::new(error.span(), error))?;

    syn::parse2(stable(tokens))
}

fn stable(tokens: TokenStream) -> TokenStream {
    let tokens: Vec<TokenTree> = tokens.into_iter().collect();
    let mut stable = Vec::with_capacity(tokens.len());
    let mut skip_const_at = None;
    let mut index = 0;

    while index < tokens.len() {
        let next = tokens.get(index + 1);

        match &tokens[index] {
            // `T: [const] Trait`
            TokenTree::Group(group)
                if group.delimiter() == Delimiter::Bracket
                    && only_ident(&group.stream(), "const") =>
            {
                index += 1;
            }
            // `T: ~const Trait`
            TokenTree::Punct(punct) if punct.as_char() == '~' && is_ident(next, "const") => {
                index += 2;
            }
            // `const trait`, `const unsafe impl`, and `impl<T> const Trait for X`; after `*`,
            // as in `*const impl Thin`, `const` is a raw pointer's and stays.
            TokenTree::Ident(ident)
                if ident == "const"
                    && !after_star(&stable)
                    && (Some(index) == skip_const_at || item_keyword(&tokens[index + 1..])) =>
            {
                index += 1;
            }
            // `final fn`
            TokenTree::Ident(ident) if ident == "final" && is_ident(next, "fn") => {
                index += 1;
            }
            // `pub impl(self) trait`
            TokenTree::Ident(ident)
                if ident == "impl"
                    && matches!(stable.last(), Some(TokenTree::Ident(last)) if last == "pub")
                    && matches!(next, Some(TokenTree::Group(group)) if group.delimiter() == Delimiter::Parenthesis) =>
            {
                index += 2;
            }
            TokenTree::Ident(ident) if ident == "impl" => {
                skip_const_at = Some(after_generics(&tokens, index + 1));
                stable.push(tokens[index].clone());
                index += 1;
            }
            TokenTree::Group(group) => {
                let mut rewritten = Group::new(group.delimiter(), self::stable(group.stream()));
                rewritten.set_span(group.span());
                stable.push(TokenTree::Group(rewritten));
                index += 1;
            }
            token => {
                stable.push(token.clone());
                index += 1;
            }
        }
    }

    stable.into_iter().collect()
}

fn after_star(tokens: &[TokenTree]) -> bool {
    matches!(tokens.last(), Some(TokenTree::Punct(punct)) if punct.as_char() == '*')
}

fn is_ident(token: Option<&TokenTree>, name: &str) -> bool {
    matches!(token, Some(TokenTree::Ident(ident)) if ident == name)
}

fn only_ident(tokens: &TokenStream, name: &str) -> bool {
    let tokens: Vec<TokenTree> = tokens.clone().into_iter().collect();
    matches!(tokens.as_slice(), [TokenTree::Ident(ident)] if ident == name)
}

/// Whether the tokens start a trait or impl, perhaps an unsafe one.
fn item_keyword(tokens: &[TokenTree]) -> bool {
    match tokens {
        [TokenTree::Ident(unsafe_), rest @ ..] if unsafe_ == "unsafe" => item_keyword(rest),
        [TokenTree::Ident(ident), ..] => ident == "trait" || ident == "impl",
        _ => false,
    }
}

/// The index after an impl's generic parameters, which open at `start` when it has any. The
/// `>` of a `->` arrow in a bound closes nothing.
fn after_generics(tokens: &[TokenTree], start: usize) -> usize {
    if !matches!(tokens.get(start), Some(TokenTree::Punct(punct)) if punct.as_char() == '<') {
        return start;
    }

    let mut depth = 0;

    for (index, token) in tokens.iter().enumerate().skip(start) {
        if let TokenTree::Punct(punct) = token {
            match punct.as_char() {
                '<' => depth += 1,
                '>' if !arrow(tokens, index) => {
                    depth -= 1;

                    if depth == 0 {
                        return index + 1;
                    }
                }
                _ => {}
            }
        }
    }

    tokens.len()
}

fn arrow(tokens: &[TokenTree], index: usize) -> bool {
    index > 0
        && matches!(&tokens[index - 1], TokenTree::Punct(punct)
            if punct.as_char() == '-' && punct.spacing() == Spacing::Joint)
}

#[cfg(test)]
mod tests {
    use quote::ToTokens;

    fn stable(source: &str) -> String {
        super::parse_file(source)
            .unwrap()
            .into_token_stream()
            .to_string()
    }

    #[test]
    fn erases_const_bounds_traits_and_impls() {
        assert_eq!(
            stable("pub const unsafe trait A: [const] B {} impl<T: ~const C, F: Fn() -> T> const A for X<T, F> {}"),
            "pub unsafe trait A : B { } impl < T : C , F : Fn () -> T > A for X < T , F > { }"
        );
    }

    #[test]
    fn erases_final_methods_and_restricted_impl_visibility() {
        assert_eq!(
            stable("pub impl(self) trait A { final fn a(&self) {} }"),
            "pub trait A { fn a (& self) { } }"
        );
    }

    #[test]
    fn keeps_raw_pointers_to_impl_types() {
        assert_eq!(
            stable("fn a(data: *const impl Thin, other: *mut impl Thin) {}"),
            "fn a (data : * const impl Thin , other : * mut impl Thin) { }"
        );
    }

    #[test]
    fn leaves_comments_and_strings_alone() {
        assert_eq!(
            stable("/// `[const] Trait` and `final fn`\nconst A: &str = \"~const\";"),
            "# [doc = \" `[const] Trait` and `final fn`\"] const A : & str = \"~const\" ;"
        );
    }
}
