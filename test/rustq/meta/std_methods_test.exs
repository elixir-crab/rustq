defmodule RustQ.Meta.StdMethodsTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.StdMethods

  test "derives which std methods mutate, iterate, and wrap" do
    assert Enum.all?(
             [:push, :push_str, :insert, :sort, :entry, :iter_mut],
             &(&1 in StdMethods.mutating())
           )

    refute Enum.any?([:len, :iter, :get, :contains], &(&1 in StdMethods.mutating()))

    assert Enum.all?(
             [:iter, :chars, :keys, :into_iter, :map, :zip, :rev],
             &(&1 in StdMethods.iterator())
           )

    refute Enum.any?([:into_boxed_slice, :len, :collect], &(&1 in StdMethods.iterator()))

    assert Enum.all?([:next, :find, :position, :try_fold], &(&1 in StdMethods.iterator_option()))
    refute :collect in StdMethods.iterator_option()

    assert Enum.all?([:is_some, :unwrap_or, :map_err, :ok_or], &(&1 in StdMethods.wrapper()))
    refute Enum.any?([:iter, :insert, :take], &(&1 in StdMethods.wrapper()))

    assert Enum.all?(
             [:len, :push, :contains_key, :to_vec, :extend],
             &(&1 in StdMethods.collection())
           )
  end

  test "keeps unstable and hidden std methods out" do
    all =
      StdMethods.mutating() ++
        StdMethods.iterator() ++
        StdMethods.iterator_option() ++ StdMethods.wrapper() ++ StdMethods.collection()

    refute Enum.any?(
             [:intersperse, :partial_sort_unstable, :assert_receiver_is_total_eq],
             &(&1 in all)
           )

    refute Enum.any?(all, &String.starts_with?(Atom.to_string(&1), "_"))
  end
end
