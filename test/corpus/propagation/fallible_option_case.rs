fn maybe_size(_key: Atom) -> NifResult<Option<f32>> {
    Ok(Some(12.0))
}

fn apply_size(key: Atom) -> NifResult<f32> {
    let value = 1.0;
    if let Some(size) = maybe_size(key)? {
        let value = size;
    }
    Ok(value)
}

fn default_size(key: Atom) -> NifResult<f32> {
    Ok(maybe_size(key)?.unwrap_or(1.0))
}

fn guarded_result_case(key: Atom) -> NifResult<f32> {
    match maybe_size(key) {
        Ok(Some(size)) if size > 0.0 => Ok(size),
        _ => Ok(0.0),
    }
}
