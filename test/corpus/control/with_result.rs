fn decode_a(term: u32) -> NifResult<u32> {
    match term {
        1 => Ok(10),
        _ => Err(rustler::Error::BadArg),
    }
}

fn decode_b(term: u32) -> NifResult<u32> {
    match term {
        2 => Ok(20),
        _ => Err(rustler::Error::BadArg),
    }
}

fn decode(term: u32) -> NifResult<u32> {
    match decode_a(term) {
        Err(_a_reason) => match decode_b(term) {
            Err(_b_reason) => Err(rustler::Error::BadArg),
            __rustq_with_value => match __rustq_with_value {
                Ok(value) => Ok(value + 1),
                Err(_reason) => Err(rustler::Error::BadArg),
            },
        },
        __rustq_with_value => match __rustq_with_value {
            Ok(value) => Ok(value + 1),
            Err(_reason) => Err(rustler::Error::BadArg),
        },
    }
}
