defmodule StatsdParser do
  @moduledoc false
  import NimbleParsec

  name = ascii_string([not: ?:], min: 1) |> unwrap_and_tag(:name)

  float =
    ascii_string([?0..?9], min: 1)
    |> choice([
      string(".") |> ascii_string([?0..?9], min: 1),
      eos()
    ])
    |> reduce({Enum, :join, [""]})
    |> map({String, :to_float, []})

  type =
    choice([
      string("|c") |> replace(:counter),
      string("|g") |> replace(:gauge),
      string("|d") |> replace(:dist),
      string("|ms") |> replace(:dist)
    ])

  sample_rate = ignore(string("|@")) |> concat(float) |> unwrap_and_tag(:sample_rate)

  tag_name = ascii_string([not: ?:], min: 1) |> unwrap_and_tag(:name)
  tag_value = ascii_string([not: ?,], min: 1) |> unwrap_and_tag(:value)

  tag_pairs =
    string("|#")
    |> ignore()
    |> repeat(
      tag_name
      |> ignore(string(":"))
      |> concat(tag_value)
      |> ignore(choice([string(","), eos()]))
      |> tag(:tag)
    )

  line =
    name
    |> ignore(string(":"))
    |> concat(choice([float, integer(min: 1)]) |> unwrap_and_tag(:value))
    |> concat(type |> unwrap_and_tag(:type))
    |> optional(sample_rate)
    |> optional(tag_pairs |> tag(:tags))

  defparsec(:parse, line)
end
