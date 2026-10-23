fn add(left: u32, right: u32) -> NifResult<u32> {
    Ok(left + right)
}

macro_rules! offset_pair {
    (fn $outer:ident;
        inner_fn $inner:ident;
        base $base:literal;
        scale $scale:expr;) => {
        fn $outer(value: u32) -> NifResult<u32> {
            $inner(value * $scale, $base)
        }

        fn $inner(value: u32, offset: u32) -> NifResult<u32> {
            add(value, offset)
        }
    };
}
offset_pair! {
fn offset_by_ten;
inner_fn offset_by;
base 10;
scale 1 + 2; }
