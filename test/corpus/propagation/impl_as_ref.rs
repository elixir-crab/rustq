fn decode<'a>(_term: Term<'a>) -> NifResult<Picture> {
    Ok(Picture::default())
}

fn run<'a>(term: Term<'a>) -> NifResult<()> {
    consume(decode(term)?);
    Ok(())
}
