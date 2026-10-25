pub struct Entry {
    values: Vec<u32>,
}

impl Entry {
    pub fn get(&self, field: u32) -> Option<u32> {
        self.values.get(field as usize).copied()
    }
}

pub fn decode_entry(bytes: &[u8]) -> NifResult<Entry> {
    Ok(Entry { values: bytes.iter().map(|byte| u32::from(*byte)).collect() })
}
