#[derive(Clone, Debug)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

pub fn decode_point<'a>(term: Term<'a>) -> NifResult<Point> {
    Ok(Point {
        x: term.map_get(atoms::x())?.decode()?,
        y: term.map_get(atoms::y())?.decode()?,
    })
}

fn decode_x<'a>(term: Term<'a>) -> NifResult<f32> {
    term.decode::<f32>()
}

fn consume(_point: Point) -> NifResult<()> {
    Ok(())
}

fn run<'a>(term: Term<'a>) -> NifResult<()> {
    let point = Point {
        x: decode_x(term)?,
        y: 0.0,
    };
    consume(point)?;
    Ok(())
}
