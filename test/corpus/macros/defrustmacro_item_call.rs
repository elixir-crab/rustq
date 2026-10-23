macro_rules! descriptor {
        (fn $name:ident;
        decoder $decoder:ident;
        field $field:ident;
        definition $definition_name:literal;
        skip_fields [$($field_id:literal, $field_repeated:literal, $field_bytes:literal, $field_skip:ident;)*]) => {
                fn $name($decoder: &mut Decoder<'_>, $field: u32) -> NifResult<()> {
                        build_fields(&[$(SkipField { id: $field_id, repeated: $field_repeated, bytes: $field_bytes, skip: $field_skip },)*])?;
                        Ok(())
                }
        };
}
descriptor! {
fn skip_document;
decoder decoder;
field field;
definition "Document";
skip_fields [
    1, false, false, skip_string;
    2, true, false, skip_child;
    3, false, true, skip_bytes;
] }
