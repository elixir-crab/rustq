# Compile-only companion probe using concrete Context<()>.
alias RustQ.Rust.AST
alias RustQ.Rust.AST.Builder, as: A
alias RustQ.Rust.AST.PatternBuilder, as: P

root = System.fetch_env!("RUSTQ_GPUI_ROOT")

{metadata, 0} =
  System.cmd("cargo", [
    "metadata",
    "--format-version",
    "1",
    "--locked",
    "--manifest-path",
    Path.join(root, "Cargo.toml")
  ])

packages = JSON.decode!(metadata)["packages"]
gpui = Enum.find(packages, &(&1["name"] == "gpui"))
context_path = Path.join(Path.dirname(gpui["manifest_path"]), "src/app/context.rs")

metadata = RustQ.Syn.parse_file!(context_path)
subscription = metadata |> RustQ.Syn.methods() |> Enum.find(&(&1.name == "subscribe_in"))
IO.inspect(subscription, label: "Actual subscribe_in metadata", limit: :infinity)

# Context<()> intentionally isolates callback support from generic declarations.
# All callback behavior is generated structurally; no Rust token escapes.
locked = A.method(A.var(:binding), :lock)
value = A.call(:number, [%AST.UnaryOp{op: :deref, expr: A.var(:value)}])
push = A.method(A.var(:guard), :push_pending, [value])

lock_body = %AST.IfLet{
  pattern: P.ok(%AST.PatVar{name: :guard, mutable: true}),
  expr: locked,
  then: [%AST.ExprStmt{expr: push}]
}

handle =
  A.match_expr(
    A.var(:event),
    Enum.map([:Change, :Release], fn variant ->
      %AST.Arm{
        pattern: P.path_tuple([:SliderEvent, variant], [:value]),
        body: [lock_body]
      }
    end)
  )

callback =
  A.closure(
    [
      P.wildcard(),
      P.wildcard(),
      {P.var(:event), %AST.TypeRef{inner: A.type_path(:SliderEvent)}},
      P.wildcard(),
      P.wildcard()
    ],
    handle,
    move: true
  )

function = %AST.Function{
  attrs: [A.allow_attr(:dead_code)],
  name: :subscribe_probe,
  args: [
    A.function_arg(:state, %AST.TypeRef{
      inner: A.type_path([:gpui, :Entity], generics: [A.type_path(:SliderState)])
    }),
    A.function_arg(:binding, A.type_path(:SharedBinding, generics: [A.type_path(:f64)])),
    A.function_arg(:window, %AST.TypeRef{inner: A.type_path([:gpui, :Window])}),
    A.function_arg(:cx, %AST.TypeRef{
      inner: A.type_path([:gpui, :Context], generics: [%AST.TypeUnit{}]),
      mutable: true
    })
  ],
  returns: A.type_path([:gpui, :Subscription]),
  body: [
    %AST.Return{
      expr: A.method(A.var(:cx), :subscribe_in, [A.var(:state), A.var(:window), callback])
    }
  ]
}

path = Path.join(root, "apps/gpui_components/native/src/slider_subscription_probe.rs")
File.write!(path, RustQ.Rust.to_fragment(function))
IO.puts("Generated #{path}")
