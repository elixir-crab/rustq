use rustler::{NifResult, Term};

include!("generated.rs");

pub mod ir;

mod ir_encoders {
    use super::ir::*;
    use rustler::Encoder;

    include!("generated_ir_encoders.rs");
}

pub fn encode_op<'a>(env: rustler::Env<'a>, op: &ir::Op<'_>) -> Term<'a> {
    ir_encoders::encode_op(env, op)
}

pub fn increment_values(values: Vec<u32>) -> Vec<u32> {
    increment_all(values)
}

pub fn decode_value(term: Term<'_>) -> NifResult<u32> {
    decode_input(term)?.value.decode()
}
