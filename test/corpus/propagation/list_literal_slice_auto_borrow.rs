fn run(style: &mut TextStyle, family: String) -> NifResult<()> {
    style.set_font_families(&[family]);
    Ok(())
}

fn use_str(_value: &str) -> NifResult<()> {
    Ok(())
}

fn string_to_str(value: String) -> NifResult<()> {
    use_str(&value)?;
    Ok(())
}

fn use_values(_values: &[u32]) -> NifResult<()> {
    Ok(())
}

fn loop_values(spans: Vec<(String, Vec<u32>)>) -> NifResult<()> {
    for (_name, values) in spans {
        use_values(&values)?;
    }
    Ok(())
}
