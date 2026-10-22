#[derive(Clone, Debug)]
pub struct Point {
    pub x: f32,
}

pub fn decode_point<'a>(term: Term<'a>) -> NifResult<Point> {
    Ok(Point {
        x: term.map_get(atoms::x())?.decode()?,
    })
}

fn decode_i64<'a>(term: Term<'a>) -> NifResult<i64> {
    term.decode::<i64>()
}

fn consume(_point: Point) -> NifResult<()> {
    Ok(())
}

fn run<'a>(term: Term<'a>) -> NifResult<()> {
    let point = Point {
        x: decode_i64(term)? as f32,
    };
    consume(point)?;
    Ok(())
}
