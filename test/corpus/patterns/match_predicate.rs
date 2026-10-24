#[derive(Clone, Debug)]
pub enum Origin {
    Assignment,
    Literal,
}

fn assigned(origin: Origin, field: u32) -> bool {
    match (origin, field) {
        (Origin::Assignment, 7) => true,
        _ => false,
    }
}
