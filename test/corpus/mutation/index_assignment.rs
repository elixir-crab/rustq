fn checked(value: u32) -> NifResult<u32> {
    if value > 100 {
        Err(rustler::Error::BadArg)
    } else {
        Ok(value)
    }
}

fn replace(mut values: Vec<u32>, index: usize, value: u32) -> NifResult<Vec<u32>> {
    values[index] = checked(value)?;
    Ok(values)
}
