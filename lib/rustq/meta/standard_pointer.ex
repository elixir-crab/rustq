defmodule RustQ.Meta.StandardPointer do
  @moduledoc false

  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  # Only fully qualified standard-library types are recognized. A user-defined
  # Arc or Mutex must not silently inherit standard-library semantics.
  def receiver(%Type{} = type) do
    case type.ast do
      %AST.TypeRef{inner: inner} ->
        receiver(Type.ast_type(inner))

      %AST.TypePath{parts: [:std, :sync, pointer], generics: [inner]}
      when pointer in [:Arc, :MutexGuard] ->
        receiver(Type.ast_type(inner))

      %AST.TypePath{parts: [:std, :boxed, :Box], generics: [inner]} ->
        receiver(Type.ast_type(inner))

      _ ->
        type
    end
  end

  def lock_result(%Type{} = type) do
    case receiver(type).ast do
      %AST.TypePath{parts: [:std, :sync, :Mutex], generics: [inner]} ->
        guard = %AST.TypePath{
          parts: [:std, :sync, :MutexGuard],
          lifetimes: [:_],
          generics: [inner]
        }

        poison = %AST.TypePath{parts: [:std, :sync, :PoisonError], generics: [guard]}
        Type.ast_type(%AST.TypeResult{ok: guard, error: poison})

      _ ->
        nil
    end
  end
end
