//! A small IR in the shape of an external crate's types, encoded by
//! `RustQ.Rustler.Term.encoders_from_source/3`.

use std::collections::HashMap;

pub struct Loc {
    pub start: u32,
    pub end: u32,
}

pub struct Expr<'a> {
    pub content: &'a str,
    pub is_static: bool,
}

pub struct Name(pub String);

pub enum Kind {
    Regular,
    KeepAlive,
}

pub struct SetProp<'a> {
    pub element: usize,
    pub values: Vec<Box<Expr<'a>>>,
    pub loc: Option<Loc>,
    pub kind: Kind,
    pub r#type: Name,
    pub attrs: HashMap<String, Expr<'a>>,
}

pub enum Op<'a> {
    SetProp(SetProp<'a>),
    Text {
        element: usize,
        values: Vec<Expr<'a>>,
    },
    Anchor(usize),
    Clear,
}
