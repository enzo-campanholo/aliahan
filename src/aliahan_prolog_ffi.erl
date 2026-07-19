-module(aliahan_prolog_ffi).

-export([run/1]).


run(Input) ->
    case executable() of
        {ok, Executable} -> run(Executable, Input);
        {error, Message} -> {error, Message}
    end.

run(Executable, Input) ->
    Runner = runner_path(),
    case filelib:is_regular(Runner) of
        true -> run_with_input_file(Executable, Runner, Input);
        false ->
            {error, iolist_to_binary(io_lib:format(
                "Could not find the Prolog scheduler runner: ~s", [Runner]
            ))}
    end.

run_with_input_file(Executable, Runner, Input) ->
    InputPath = temporary_path(),
    try
        case file:write_file(InputPath, Input, [exclusive]) of
            ok -> run_port(Executable, Runner, InputPath);
            {error, Reason} ->
                {error, format_error("Could not write Prolog input", Reason)}
        end
    catch
        Class:ExceptionReason ->
            {error, iolist_to_binary(io_lib:format(
                "Could not run SWI-Prolog: ~p:~p", [Class, ExceptionReason]
            ))}
    after
        _ = file:delete(InputPath)
    end.

executable() ->
    Name = case os:getenv("ALIAHAN_SWIPL_PATH") of
        false -> "swipl";
        Value -> Value
    end,
    case os:find_executable(Name) of
        false -> {error, <<"Could not find the SWI-Prolog executable">>};
        Path -> {ok, Path}
    end.

runner_path() ->
    case os:getenv("ALIAHAN_PROLOG_RUNNER_PATH") of
        false -> filename:absname("prolog/browser_scheduler.pl");
        Path -> filename:absname(Path)
    end.

temporary_path() ->
    Directory = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Value -> Value
    end,
    Name = "aliahan-prolog-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic])) ++
        ".json",
    filename:join(Directory, Name).

run_port(Executable, Runner, InputPath) ->
    Port = open_port(
        {spawn_executable, Executable},
        [binary, exit_status, use_stdio, stderr_to_stdout,
         {args, ["-q", "-s", Runner, "--", InputPath]}]
    ),
    collect(Port, os_pid(Port), []).

os_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} -> OsPid;
        _ -> undefined
    end.

collect(Port, OsPid, Chunks) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, OsPid, [Data | Chunks]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Chunks))};
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Chunks)),
            {error, failure_message(Status, Output)}
    after 30000 ->
        kill_os_process(OsPid),
        _ = try port_close(Port) of
            _ -> ok
        catch
            _:_ -> ok
        end,
        {error, <<"SWI-Prolog did not finish within 30 seconds">>}
    end.

%% port_close/1 only closes the pipes; without an explicit kill the
%% swipl process keeps running.
kill_os_process(undefined) ->
    ok;
kill_os_process(OsPid) ->
    _ = os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    ok.

failure_message(Status, <<>>) ->
    iolist_to_binary(io_lib:format(
        "SWI-Prolog exited with status ~B", [Status]
    ));
failure_message(_Status, Output) ->
    Output.

format_error(Prefix, Reason) ->
    iolist_to_binary(io_lib:format("~s: ~p", [Prefix, Reason])).
