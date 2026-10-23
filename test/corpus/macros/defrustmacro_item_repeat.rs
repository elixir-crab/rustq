#[derive(Clone, Debug)]
pub struct Field {
    pub id: u32,
    pub name: &'static str,
    pub repeated: bool,
    pub decode: fn(),
}

macro_rules! descriptor {
        (fn $name:ident;
        fields [$($field_id:literal, $field_name:literal, $field_mode:ident, $field_decode:ident;)*]) => {
                fn $name() -> NifResult<()> {
                        build_fields(&[$(Field { id: $field_id, name: $field_name, repeated: repeated!($field_mode), decode: $field_decode },)*])
                }
        };
}

fn build_fields(_fields: &[Field]) -> NifResult<()> {
    Ok(())
}
