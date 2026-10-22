fn log_value(value: u32) -> NifResult<()> {
    Debug::trace!(value);
    Ok(())
}
