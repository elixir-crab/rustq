fn touch(_value: &mut u32) {}

fn run(value: u32) {
    let mut local = value;
    touch(&mut local);
}
