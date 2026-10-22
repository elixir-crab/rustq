fn read_field() -> NifResult<u32> {
    Ok(1)
}

fn skip_field() -> NifResult<()> {
    match read_field()? {
        0 => Ok(()),
        _field_id => Err(rustler::Error::BadArg),
    }
}
