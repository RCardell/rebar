
-define(config_file, upgrade.config).
-define(quit(Reason),
        io:format("### Fail ### ~p, line ~p~n~n",[Reason, ?LINE]),
        halt(1)).

%% this macro is because we would like the line numbers in exceptions
-define(lkup(__K, __L), (try lkup(__K,__L)
                         catch
                             _:_ -> ?quit({key_not_defined, __K, __L})
                         end)).

-define(log(S,A), (io:format("~s - " ++S++"~n",[local_time()|A]))).
-define(log(Term), ?log("~p~n",[Term])).
-define(log, ?log("",[])).

-mode(compile).

main(_)->
    try
        Config = read_config_file(),
        %%setup_test_app(),
        connect(Config),
        copy_tar(Config),
        unpack_release(Config),
        pre_check_release(Config),
        install_release(Config),
        make_permanent(Config),
        ?log("Success.")
    catch
        E:R ->
            ?quit({E,R})
    end.

read_config_file() ->
    {ok, Config} = file:consult(?config_file),
    assert_mandatory_fields(Config),
    Config.

assert_mandatory_fields(Config) ->
    Fields = [binary
            , remote_node
            , prev_rel
            , release
            , release_tar
            , old_version
            , new_version],
    Missing = [ F || F <- Fields,
                     false =:= lists:keyfind(F, 1, Config)],
    case Missing of
        [] -> ok;
        M -> ?quit({missing_config_fields, {missing, M}, {cfg, Config}})
    end.


connect(Config) ->
    RemoteNode = get_node_name(Config),
    net_kernel:start([shell, shortnames]),
    ?log("Connecting to node: ~p (from ~p)",[RemoteNode, node()]),
    case net_adm:ping(RemoteNode) of
        pong -> ok;
        pang ->
            Str = lists:flatten(
                    io_lib:format("Remote node not responding: ~p. Is it up?",
                                  [RemoteNode])),
            ?quit({node_not_responding, Str})
    end.

get_node_name(Config) ->
    RemoteNode = ?lkup(remote_node, Config),
    L = atom_to_list(RemoteNode),
    case lists:member(L, $@) of
        true -> RemoteNode;
        false ->
            {ok, Hostname} = inet:gethostname(),
            list_to_atom(L ++ "@" ++ Hostname)
    end.

setup_test_app() ->
    os:cmd("./rel/calc_first/bin/calc stop"),
    timer:sleep(500),
    "" = os:cmd("rm -rf rel/calc_first"),
    "" = os:cmd("cp rel/calc_first_copy rel/calc_first -r"),
    "" = os:cmd("./rel/calc_first/bin/calc start"),
    timer:sleep(1000),
    "pong\n" = os:cmd("./rel/calc_first/bin/calc ping"),
    ?log("Node resetted").

unpack_release(Config) ->
    ?log("Unpacking..."),
    Release = ?lkup(release, Config),
    NewVersion = ?lkup(new_version, Config),
    OldVersion = ?lkup(old_version, Config),
    Res = rpc_call(Config, release_handler, unpack_release, [Release]),
    case Res of
        {ok, NewVersion} -> ok;
        {error, {existing_release, Ver}=Err} ->
            ?log("Expected release ~p, but was actually ~p",[OldVersion, Ver]),
            ?quit({unpack_release, Err});
        {error, Reason} -> ?quit({unpack_release, Reason})
    end.

pre_check_release(Config) ->
    NewVersion = ?lkup(new_version, Config),
    case rpc_call(Config, release_handler, check_install_release,
                  [NewVersion]) of
        {ok, _Vsn, _Descr} ->
            ?log("The new version seems installable");
        {error, _R} = Err -> ?quit({assert_can_install_version, Err})
    end.


install_release(Config) ->
    NewVersion = ?lkup(new_version, Config),
    OldVersion = ?lkup(old_version, Config),
    ?log("Installing..."),
    {ok, OldVersion, _} =
        rpc_call(Config, release_handler, install_release, [NewVersion]),
    ?log("Install successful").

make_permanent(Config) ->
    NewVersion = ?lkup(new_version, Config),
    ok =
        rpc_call(Config, release_handler, make_permanent, [NewVersion]).

copy_tar(Config) ->
    ReleaseTar = ?lkup(release_tar, Config).
    %% PrevRel = ?lkup(prev_rel, Config),
    %% ?log("Copying tar to release dir"),
    %% From = filename:join(["..", ReleaseTar]),
    %% To   = filename:join(["..", releases, ReleaseTar]),
    %% Res = os:cmd("cp " ++  From ++ " " ++ To),
    %% case Res of
    %%     "" -> ok;
    %%     Res -> ?log("### Error #### moving ~p to ~p failed ~n "
    %%                 "with reason ~p", [From, To, Res]),
    %%            ?quit(Res)
    %% end.

rpc_call(Config, M, F, A) ->
    RemoteNode = ?lkup(remote_node, Config),
    rpc:call(RemoteNode, M, F ,A).

local_time() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:local_time(),
    lists:flatten(io_lib:format("~w-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w",
                                [Year, Month, Day, Hour, Minute, Second])).

lkup(K, L) ->
    {K, V} = lists:keyfind(K, 1, L),
    V.
