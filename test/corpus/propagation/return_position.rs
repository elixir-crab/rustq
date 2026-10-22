fn decode<'a>(atom: Term<'a>) -> NifResult<u32> {
    atom.decode::<u32>()
}

fn use_decode<'a>(atom: Term<'a>) -> NifResult<u32> {
    let value = decode(atom)?;
    Ok(value)
}
