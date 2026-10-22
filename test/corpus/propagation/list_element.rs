fn decode<'a>(term: Term<'a>) -> NifResult<Color> {
    let value = term.decode::<u32>()?;
    Ok(Color::from_argb(255, 0, 0, value))
}

fn consume(_colors: Vec<Color>) -> NifResult<()> {
    Ok(())
}

fn run<'a>(term: Term<'a>) -> NifResult<()> {
    consume(vec![decode(term)?])?;
    Ok(())
}
