defmodule State do
  defstruct processing: [],
            pending: [],
            output: %{},
            status: %{},
            exit_status: %{},
            timeout: 10000,
            threads: 5,
            lookup: %{},
            queue: %{},
            n: 0
end

defmodule Server do
  use GenServer

  def get_files() do
    ls = File.ls!("/home/caligian") |> Enum.map(&("/home/caligian/#{&1}"))
    ls = Enum.filter(ls, &File.dir?/1)
    ls = Enum.map ls, &(~s(ls "#{&1}"))
    # ls = Enum.map(1..10, fn _ -> "ruby test.rb" end)
    ls
  end

  def init({cmds, opts}) do
    n = length(cmds)
    state = %State{n: n}
    state = Map.merge(state, opts)
    cmds = Enum.chunk_every(cmds, state.threads)

    Process.flag(:trap_exit, true)

    {:ok, %State{state | pending: cmds}}
  end

  def open_port(state) do
    current = hd(state.pending)

    pids =
      Enum.map(current, fn cmd ->
        pid =
          Port.open({:spawn, cmd}, [
            :binary,
            :stderr_to_stdout,
            {:line, 30},
            :use_stdio,
            :exit_status,
          ])

        Port.monitor(pid)

        {pid, cmd}
      end)

    queue =
      List.foldl(pids, %{}, fn {pid, cmd}, acc ->
        Map.put(acc, pid, cmd)
      end)

    state = %State{state | processing: [], lookup: Map.merge(state.lookup, queue), queue: queue}

    state =
      case state.pending do
        [x] -> %State{state | processing: x, pending: []}
        x -> %State{state | processing: hd(x), pending: tl(x)}
      end

    state
  end

  def completed?(state) do
    map_size(state.exit_status) == state.n
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:running?, _, state) do
    case map_size(state.exit_status) == state.n do
      false -> {:reply, true, state}
      true -> {:reply, false, state}
    end
  end

  def handle_call(:run, _, state) when map_size(state.queued) > 0 do
    {:reply, :pending, state}
  end

  def handle_call(:run, _, state) when state.pending == [] do
    {:reply, :empty_queue, state}
  end

  def handle_call(:run, _, state) do
    case completed?(state) do
       true -> 
        {:stop, :completed, state, %State{}}

      false ->
        {:reply, :queued, open_port(state)}
    end
  end

  def handle_call(:output, _, state) do
    {:reply, state.output, state}
  end

  defp add_output(state, pid, out) do
    %State{
      state
      | output: Map.update(state.output, pid, [out], fn current -> [out | current] end)
    }
  end

  def pop_pid(state, pid) do
    if Map.get(state.queue, pid) do
      {_, map} = Map.pop!(state.queue, pid)
      %State{state | queue: map}
    else
      state
    end
  end

  defp on_closing(msg, state) do
    {pid, tp, reason} =
      case msg do
        {:DOWN, _ref, :port, pid, reason} ->
          {pid, :status, reason}

        {:EXIT, pid, reason} ->
          {pid, :status, reason}

        {pid, {:exit_status, status}} ->
          {pid, :exit_status, status}

        {pid, {:closed, reason}} ->
          {pid, :status, reason}
      end

    {_, queue} = Map.pop(state.queue, pid)

    state = %State{state | queue: queue}

    state =
      cond do
        tp == :status ->
          %State{state | status: Map.put(state.status, pid, reason)}

        tp == :exit_status ->
          %State{state | exit_status: Map.put(state.exit_status, pid, reason)}
      end

    state =
      cond do
        length(state.pending) > 0 ->
          open_port(state)

        true ->
          state
      end

    state
  end

  def handle_info({pid, {:data, {:eol, line}}}, state) do
    {:noreply, add_output(state, pid, line)}
  end

  def handle_info({_pid, {:data, {:noeol, _}}}, state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    {:noreply, on_closing(msg, state)}
  end

  def start_link() do
    cmds = get_files()
    opts = %{}
    {:ok, pid} = GenServer.start_link(__MODULE__, {cmds, opts}, name: __MODULE__)

    pid
  end

  def call(msg) do
    GenServer.call(__MODULE__, msg)
  end

  def cast(msg) do
    GenServer.cast(__MODULE__, msg)
  end

  def stop() do
    GenServer.stop(__MODULE__)
  end

  def get_state() do
    GenServer.whereis(__MODULE__) |> :sys.get_state
  end
end

defmodule Runner do
  use GenServer

  def init(n) do
    pid = Server.start_link()

    Port.monitor(pid)
    Process.flag(:trap_exit, true)
    Server.call(:run)

    {:ok, %{server: pid, output: %{}, completed: false}}
  end

  def handle_call(:collect, _, state) when state.completed do
    server_state = Server.get_state()
    state = %{state | output: Map.merge(server_state.output, state.output)}
    {:stop, :completed, state.output, %{}}
  end

  def handle_call(:collect, from, state) do
    server_state = :sys.get_state(state.server)

    case Server.call(:running?) do
      true -> 
        me = self()
        out = Server.call(:run) 
        send me, {me, out}

        receive do
          {^me, :empty_queue} -> 
            handle_call(:collect, from, state)

          {^me, :pending} ->
            handle_call(:collect, from, state)

          _ -> 
            handle_call(:collect, from, %{state | output: Map.merge(state.output, server_state.output) })
        after
          server_state.timeout ->
            handle_call(:collect, from, state)
        end

      false ->
        {:stop, :empty_queue, server_state.output, %{}}
    end
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [5], [name: __MODULE__])
  end

  def handle_info({:EXIT, ^state.server, _}, state) do
    server_state = :sys.get_state(state.server)

    {:noreply, %{state | 
      output: Map.merge(state.output, server_state.output),
      completed: true}}
  end

  def handle_info({:DOWN, _, :port, ^state.server, _}, state) do
    server_state = :sys.get_state(state.server)

    {:noreply, %{state | 
      output: Map.merge(state.output, server_state.output),
      completed: true}}
  end

  def call(msg, timeout) do
    GenServer.call(__MODULE__, msg, timeout)
  end

  def cast(msg) do
    GenServer.cast(__MODULE__, msg)
  end

  def get_state() do
    :sys.get_state(Runner)
  end
end
