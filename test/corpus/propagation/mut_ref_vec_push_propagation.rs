fn make_term() -> u32 {
    0
}

fn decode_value() -> NifResult<u32> {
    Ok(make_term())
}

fn run(values: &mut Vec<u32>) -> NifResult<()> {
    values.push(decode_value()?);
    Ok(())
}
