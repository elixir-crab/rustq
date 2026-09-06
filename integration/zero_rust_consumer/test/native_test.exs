defmodule RustQZeroRustConsumer.NativeTest do
  use RustQ.Test, async: true

  alias RustQZeroRustConsumer.{Circle, Native, NativeError, Point, Rectangle}

  test "decodes local structural aliases in expressions" do
    assert Native.decode_local_coordinates(%{x: 1.5, y: 2.0}) == %{x: 1.5, y: 2.0}
    assert Native.decode_local_x(%{x: 1.5, y: 2.0}) == 1.5
    assert_raise ArgumentError, fn -> Native.decode_local_coordinates(:invalid) end
    assert_raise ArgumentError, fn -> Native.decode_local_x(:invalid) end
  end

  test "shape queries evaluate side-effecting arguments exactly once" do
    assert Native.shape_evaluation_count() == 3
  end

  test "constant shape queries still evaluate fallible arguments" do
    assert Native.evaluated_pair_size({1, 2}) == 2
    assert Native.evaluated_map_size(%{x: 1.0, y: 2.0}) == 2
    assert Native.evaluated_has_key(%{x: 1.0, y: 2.0})

    for query <- [
          &Native.evaluated_pair_size/1,
          &Native.evaluated_map_size/1,
          &Native.evaluated_has_key/1
        ] do
      assert_raise ArgumentError, fn -> query.(:invalid) end
    end
  end

  test "result-returning closures and captures preserve native composition" do
    assert Native.closure_results([1, 0, 3]) == [{:ok, 12}, {:error, "nonpositive"}, {:ok, 14}]
    assert Native.captured_results([1, 0, 3]) == [{:ok, 2}, {:error, "nonpositive"}, {:ok, 4}]
    assert Native.closure_results([]) == []
    assert Native.captured_results([]) == []
  end

  test "native numeric contracts are explicit at boundaries" do
    max = 9_223_372_036_854_775_807
    min = -9_223_372_036_854_775_808
    assert Native.checked_addition(max - 1, 1) == max
    assert Native.checked_addition(max, 1) == nil
    assert Native.checked_addition(min, -1) == nil
    assert Native.checked_division(4, 0) == nil
    assert Native.checked_division(min, -1) == nil
    assert_raise ArgumentError, fn -> Native.checked_addition(max + 1, 0) end

    for left <- [-17, -1, 0, 1, 17], right <- [-5, -2, 1, 2, 5] do
      assert Native.integer_quotient(left, right) == div(left, right)
      assert Native.integer_remainder(left, right) == rem(left, right)
      assert Native.checked_division(left, right) == div(left, right)
      assert Native.floating_quotient(left, right) == left / right
    end
  end

  test "Cargo features select exactly one NIF implementation" do
    expected =
      if System.get_env("RUSTQ_TEST_FEATURE") == "1", do: {:ok, 6}, else: {:error, "disabled"}

    assert Native.feature_boundary(4) == expected
  end

  test "conditional NIFs load exactly one implementation" do
    expected =
      if System.get_env("RUSTQ_TEST_RELEASE") == "1", do: {:error, "release"}, else: {:ok, 5}

    assert Native.conditional_boundary(4) == expected
    assert function_exported?(Native, :conditional_boundary, 1)
  end

  test "cond preserves result types in every branch" do
    assert Native.conditional_result(-1) == {:error, "negative"}
    assert Native.conditional_result(0) == {:ok, 0}
    assert Native.conditional_result(4) == {:ok, 2}
  end

  test "result NIFs compose through native calls and recursion" do
    assert Native.recursive_result(4) == {:ok, 1}
    assert Native.recursive_result(0) == {:error, "nonpositive"}
    assert Native.composed_result(4) == {:ok, 2}
    assert Native.composed_result(0) == {:error, "nonpositive"}
  end

  test "adapts only the outer result boundary" do
    assert Native.nested_result(3) == {:ok, 4}
    assert Native.nested_result(0) == {:error, "nonpositive"}
    assert Native.forwarded_result(3) == {:ok, 3}
    assert Native.forwarded_result(0) == {:error, "nonpositive"}
  end

  test "lowers arithmetic, recursion, guards, comprehensions, and Enum pipelines" do
    assert Native.add(20, 22) == 42
    assert Native.sum([1.5, 2.0, 3.5]) == 7.0
    assert Native.factorial(6) == 720
    assert Native.env_roundtrip(%{value: [1, 2, 3]}) == %{value: [1, 2, 3]}
    assert Native.guarded_sign(10) == 1
    assert Native.guarded_sign(-10) == -1
    assert Native.guarded_sign(0) == 0
    assert Native.recursive_sum([1, 2, 3, 4]) == 10
    assert Native.recursive_sum([]) == 0
    assert Native.squares([2, 3, 4]) == [4, 9, 16]
    assert Native.positives([-2, 0, 3, 5]) == [3, 5]
    assert Native.total([10, 20, 12]) == 42
    assert Native.positive_square_sum([-3, 0, 2, 4]) == 20
  end

  test "derives map, struct, enum, union, exception, and resource codecs" do
    assert Native.translate(%{x: 1.5, y: 2.0}, 3.0, -1.0) == %{x: 4.5, y: 1.0}
    assert Native.coordinate_sum(%{x: 10.5, y: 2.0}) == 12.5
    assert Native.guarded_coordinate(%{x: 2.0, y: 1.0}) == 2.0
    assert Native.guarded_coordinate(%{x: -2.0, y: 1.0}) == 0.0
    assert Native.invert_mode(:fast) == :safe
    assert Native.invert_mode(:safe) == :fast
    assert Native.scale_point(%Point{x: 2.0, y: 3.0}, 2.5) == %Point{x: 5.0, y: 7.5}

    circle = %Circle{radius: 2.0}
    rectangle = %Rectangle{width: 4.0, height: 3.0}
    assert Native.shape_area(circle) == 4.0
    assert Native.shape_area(rectangle) == 12.0
    assert Native.echo_shape(circle) == circle
    assert Native.echo_shape(rectangle) == rectangle

    error = %NativeError{message: "native failure"}
    assert Native.echo_error(error) == error

    counter = Native.new_counter(42)
    assert is_reference(counter)
    assert Native.counter_value(counter) == 42
  end

  test "derives option and tagged result boundaries" do
    assert Native.maybe_increment(nil) == nil
    assert Native.maybe_increment(41) == 42
    assert Native.safe_div(42, 6) == {:ok, 7}
    assert Native.safe_div(42, 0) == {:error, "division by zero"}
  end

  test "calls an external crate and handles binary boundaries" do
    assert Native.checksum("123456789") == 0xCBF43926
    assert Native.byte_count(<<0, 1, 2, 3>>) == 4
    assert Native.valid_utf8("rustq")
    refute Native.valid_utf8(<<255>>)
  end

  test "lowers the supported Kernel and Range subset" do
    assert Native.within_byte(255)
    refute Native.within_byte(256)
    assert Native.includes([1, 3, 5], 3)
    refute Native.includes([1, 3, 5], 4)
    assert Native.integer_abs(-42) == 42
    assert Native.integer_min(7, 3) == 3
    assert Native.byte_size_of("hé") == 3
    assert Native.list_length([1, 2, 3]) == 3
    assert Native.coordinate_size(%{x: 1.0, y: 2.0}) == 2
    assert Native.pair_first({10, 20}) == 10
    assert Native.pair_replace({10, 20}, 30) == {10, 30}
    assert Native.pair_size({10, 20}) == 2
  end

  test "lowers the supported Enum and List subset" do
    assert Native.count_values([1, 2, 3]) == 3
    assert Native.count_positive([-1, 0, 2, 3]) == 2
    assert Native.values_empty([])
    refute Native.values_empty([1])
    assert Native.find_positive([-2, 0, 3, 4]) == 3
    assert Native.find_positive([-2, 0]) == nil
    assert Native.concat_values([[1, 2], [], [3]]) == [1, 2, 3]
    assert Native.zip_values([1, 2], [3, 4, 5]) == [{1, 3}, {2, 4}]
    assert Native.unzip_values([{1, 3}, {2, 4}]) == {[1, 2], [3, 4]}
    assert Native.reverse_values([1, 2, 3]) == [3, 2, 1]
    assert Native.sort_values([3, 1, 2]) == [1, 2, 3]
    assert Native.take_two([1, 2, 3]) == [1, 2]
    assert Native.drop_one([1, 2, 3]) == [2, 3]
    assert Native.first_value([5, 6]) == 5
    assert Native.first_value([]) == nil
    assert Native.last_value([5, 6]) == 6
    assert Native.flatten_values([[[1], [2, 3]], [[]]]) == [1, 2, 3]
    assert Native.first_or([], 9) == 9
    assert Native.first_or([5], 9) == 5
    assert Native.wrap_value(7) == [7]
    assert Native.duplicate_value(4) == [4, 4, 4]
  end

  test "lowers typed Map, String, and Tuple operations" do
    point = %{x: 1.5, y: 2.5}
    assert Native.coordinate_x(point) == 1.5
    assert Native.coordinate_get_x(point) == 1.5
    assert Native.coordinate_get_missing(point, 9) == 9
    assert Native.coordinate_has_x(point)
    assert Native.coordinate_put_x(point, 8.0) == %{x: 8.0, y: 2.5}

    assert Native.starts_with("rustq", "rust")
    assert Native.ends_with("rustq", "stq")
    assert Native.string_contains("rustq", "us")
    assert Native.trim_string("  rustq \n") == "rustq"
    assert Native.replace_string("a-b-a", "a", "x") == "x-b-x"
    assert Native.duplicate_string("rq") == "rqrqrq"
    assert Native.tuple_to_list({1, 2, 3}) == [1, 2, 3]
  end

  test "exposes focused generated-source helpers" do
    assert nif_exported?(Native, :guarded_sign, 1)
    assert rust_source!(Native, :guarded_sign) =~ ~r/value if value > 0/
    assert RustQ.valid?(rust_source!(Native), "zero_rust_native.rs")
  end
end
