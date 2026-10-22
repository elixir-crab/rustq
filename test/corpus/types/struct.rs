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

fn origin() -> Point {
    Point { x: 0.0, y: 0.0 }
}
