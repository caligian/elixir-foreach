defmodule Foreach do
  def get_placeholders(cmd) do
    regex = ~r"(?<=%)([a-zA-Z0-9_-]+)"
    repl = Regex.scan(regex, cmd)
    repl =
      case repl do
        [] ->
          %{}

        _ ->
          repl
          |> List.foldl(%{}, fn [_, x], acc ->
            Map.put(acc, x, ~r/%#{x}/)
          end)
      end

    repl
  end

  defp get_subs([], _, _, parsed) do
    parsed
  end

  defp get_subs([line | rest], placeholders, regexes, parsed) do
    match =
      List.foldl(
        Map.keys(regexes),
        %{"_" => line, "basename" => Path.basename(line), "realpath" => Path.absname(line)},
        fn placeholder, acc ->
          m = Regex.run(regexes[placeholder], line)

          case m do
            nil ->
              if Map.has_key?(placeholders, placeholder) do
                throw({:missing_definition, [placeholder: placeholder, line: line]})
              else
                acc
              end

            _ ->
              Map.put(acc, placeholder, List.last(m))
          end
        end
      )

    get_subs(rest, placeholders, regexes, [match | parsed])
  end

  defp do_subs(_, _, [], cmds) do
    cmds
  end

  defp do_subs(cmd, placeholders, [match | rest_parsed], cmds) do
    parsed_cmd =
      List.foldl(Map.keys(placeholders), cmd, fn placeholder, s ->
        case Map.has_key?(match, placeholder) do
          true ->
            regex = placeholders[placeholder]
            sub = match[placeholder]
            Regex.replace(regex, s, sub)

          false ->
            s
        end
      end)

    do_subs(cmd, placeholders, rest_parsed, [parsed_cmd | cmds])
  end

  defp collect_output(pid, parsed, i, n, timeout) do
    cond do
      i == n ->
        parsed

      true ->
        receive do
          {:err, ^pid} ->
            collect_output(pid, parsed, i + 1, n, timeout)

          {:ok, ^pid, out} ->
            collect_output(pid, [out | parsed], i + 1, n, timeout)
        after
          timeout -> parsed
        end
    end
  end

  defp run_cmds(cmds, options) do
    this = self()

    run_cmd = fn cmds ->
      spawn(fn ->
        for x <- cmds do
          {out, exit_code} = System.shell(x)

          case exit_code do
            0 ->
              if not options[:quiet], do: IO.write(out)
              send(this, {:ok, self(), out})

            _ ->
              send(this, {:err, self(), [exit_code: exit_code, cmd: x]})
          end
        end
      end)
    end

    Enum.chunk_every(cmds, options[:threads])
    |> List.foldl([], fn range, acc ->
      pid = run_cmd.(range)
      out = collect_output(pid, [], 0, length(range), options[:timeout])
      acc ++ out
    end)
  end

  def run!(cmd, lines, defs, options) do
    placeholders = get_placeholders(cmd)
    subs = get_subs(lines, placeholders, defs, [])
    cmds = do_subs(cmd, placeholders, subs, [])

    run_cmds(cmds, options)
  end

  def test() do
    regexes = %{"line" => ~r/\b([a-z0-9]+)\b/}
    lines = Enum.to_list(0..10) |> Enum.map(&Integer.to_string/1)
    cmd = "zecho %line"
    threads = 3

    run!(cmd, lines, regexes, threads)
  end

  def main() do
    args = parse_cmdline()
    cmd = args[:cmd]
    lines = args[:lines]
    opts = args[:options]

    case args[:defs] do
      x when is_list(x) ->
        defs =
          Enum.chunk_every(x, 2)
          |> List.foldl(%{}, fn [name, regex], acc ->
            Map.put(acc, name, Regex.compile!(regex))
          end)

        run!(cmd, lines, defs, opts)

      _ ->
        run!(cmd, lines, %{}, opts)
    end
  end

  def parse_cmdline() do
    specs = [
      %{name: "d", long: "define", n: "*"},
      %{name: "i", long: "stdin", without: ["f"]},
      %{name: "f", long: "file", n: 1, without: ["i"], type: :contents},
      %{name: "j", long: "threads", n: "?", type: :int, default: fn -> 5 end},
      %{name: "r", long: "run", n: 1},
      %{name: "q", long: "quiet"},
      %{name: "s", long: "sep", n: 1, default: fn -> ~r"[\n\r]" end, type: :regex},
      %{name: "t", long: "timeout", n: 1, default: fn -> 200 end, type: :integer}
    ]

    {:ok, parsed} = Argparser.parse!("Drop-in replacement for xargs", specs)
    {pos, named} = parsed
    cmd = Enum.join(pos, " ")

    unless length(pos) > 0 do
      raise WrongSpecError, "no positional args provided"
    end

    lines =
      cond do
        named[:stdin] ->
          Argparser.get_stdin(named[:sep])

        named[:file] ->
          String.split(named[:file], named[:sep])

        named[:run] ->
          {out, exit_code} = System.shell(named[:run])

          if exit_code != 0 do
            raise WrongSpecError, message: "cmd failed in shell: #{named[:run]}"
          else
            String.split(out, named[:sep])
          end
      end

    %{
      lines: lines,
      cmd: cmd,
      defs: named[:define] || false,
      options: %{
        quiet: named[:quiet] || false,
        threads: named[:threads],
        timeout: named[:timeout]
      }
    }
  end
end

defmodule Foreach.CLI do
  def main(_ \\ []) do
    Foreach.main()
  end
end
