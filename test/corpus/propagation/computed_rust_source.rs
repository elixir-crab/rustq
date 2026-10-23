fn decode_color<'a>(term: Term<'a>) -> NifResult<Color> {
    let color = term.decode::<u32>()?;
    Ok(Color::from_argb(255, 0, 0, color))
}

fn draw<'a>(term: Term<'a>, opts: &[(Atom, Term<'a>)]) -> NifResult<()> {
    stroke_paint(decode_color(term)?, 1.0, opts)?;
    Ok(())
}
