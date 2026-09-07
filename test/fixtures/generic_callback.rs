pub struct Context<T> {
    pub owner: T,
}

impl<T> Context<T> {
    pub fn accept<U>(&mut self, value: &U, callback: impl Fn(&T, &U) -> usize) -> usize {
        callback(&self.owner, value)
    }
}
