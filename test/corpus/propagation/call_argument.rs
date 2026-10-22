fn decode<'a>(atom: Term<'a>) -> NifResult<u32> {
    atom.decode::<u32>()
}

fn consume(value: u32) -> NifResult<()> {
    let _copy = value;
    Ok(())
}

fn run<'a>(atom: Term<'a>) -> NifResult<()> {
    consume(decode(atom)?)?;
    Ok(())
}
