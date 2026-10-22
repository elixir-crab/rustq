#[derive(Clone, Debug)]
pub struct Field {
    pub id: u32,
}

pub fn decode_field<'a>(term: Term<'a>) -> NifResult<Field> {
    Ok(Field {
        id: term.map_get(atoms::id())?.decode()?,
    })
}

fn read_id() -> NifResult<u32> {
    Ok(0)
}

fn run(fields: &[Field]) -> NifResult<()> {
    let field_id = read_id()?;
    if field_id == 0 {
        Ok(())
    } else {
        match fields.binary_search_by_key(&field_id, |field| field.id) {
            Ok(_index) => Ok(()),
            Err(_index) => Err(rustler::Error::BadArg),
        }
    }
}
