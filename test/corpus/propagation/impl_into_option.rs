fn decode_filter<'a>(_term: Term<'a>) -> NifResult<ImageFilter> {
    Ok(ImageFilter::default())
}

fn run<'a>(paint: &mut Paint, term: Term<'a>) -> NifResult<()> {
    paint.set_image_filter(decode_filter(term)?);
    Ok(())
}

fn optional_matrix<'a>(_term: Term<'a>) -> NifResult<Option<Matrix>> {
    Ok(None)
}

fn run_ref_option<'a>(effect: &RuntimeEffect, term: Term<'a>) -> NifResult<Shader> {
    effect
        .make_shader(optional_matrix(term)?.as_ref())
        .ok_or(rustler::Error::BadArg)?
}
