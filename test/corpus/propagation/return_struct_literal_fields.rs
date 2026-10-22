#[derive(Clone, Debug)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

pub fn decode_point<'a>(term: Term<'a>) -> NifResult<Point> {
    Ok(Point {
        x: term.map_get(atoms::x())?.decode()?,
        y: term.map_get(atoms::y())?.decode()?,
    })
}

fn decode_float<'a>(term: Term<'a>) -> NifResult<f64> {
    term.decode::<f64>()
}

fn run<'a>(term: Term<'a>) -> NifResult<Point> {
    Ok(Point {
        x: decode_float(term)?,
        y: decode_float(term)? as f64,
    })
}
