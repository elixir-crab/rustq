use RustQ.Config

alias RustQ.Rust.AST.Builder, as: A
alias RustQ.Rustler.{Atom, Term}

require_file("lib/rustq_public_consumer/generated.ex")

rust "native/src/generated.rs" do
  [
    A.const(:ANSWER, :u32, 42, vis: :pub),
    Atom.declaration([:ok, :value]),
    RustQPublicConsumer.Generated.__rustq_items__(),
    Term.decoder(:Input,
      fields: [
        value: [type: "Term<'a>", key: A.path_call([:atoms, :value]), required: true]
      ]
    )
  ]
end

ir_sources = ["native/src/ir.rs"]
ir_opts = [tag: :kind, types: [SetProp: [fields: [kind: [key: :prop_kind]]]]]

rust "native/src/generated_ir_encoders.rs" do
  [
    Atom.declaration(Term.encoder_atoms_from_source(ir_sources, ["Op"], ir_opts)),
    Term.encoders_from_source(ir_sources, ["Op"], ir_opts)
  ]
end
