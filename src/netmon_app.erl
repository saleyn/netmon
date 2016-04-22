%%%------------------------------------------------------------------------
%%% File: $Id$
%%%------------------------------------------------------------------------
%%% @doc     Application for monitoring network of connected nodes.
%%% @author  Serge Aleynikov <saleyn@gmail.com>
%%% @version $Revision$
%%% @end
%%%----------------------------------------------------------------------
%%% Created: 2007-01-10 by Serge Aleynikov <saleyn@gmail.com>
%%% $URL$
%%%----------------------------------------------------------------------
-module(netmon_app).
-author('saleyn@gmail.com').
-id    ("$Id$").

-behaviour(application).

%% application and supervisor callbacks
-export([start/2, stop/1, init/1]).

%% Internal exports
-export([start_monitor/1, get_node_opts/1]).

-include_lib("lama/include/logger.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @doc A startup function for spawning new monitor process
%%      Called by the netmon:add_monitor/1.
%% @see netmon:add_monitor/1
%% @see netmon_instance:start_link/7
%% @private
%% @end
%%----------------------------------------------------------------------
start_monitor({Name, App, Type, Nodes, Notify, Interval}) ->
    start_monitor({Name, App, Type, Nodes, Notify, Interval, udp});
start_monitor({Name, _App, _Type, _Nodes, _Notify, _Interval, _PingType} = Tuple) ->
    Args = tuple_to_list(Tuple),
    % Netmon Instance
    ChildSpec = {   Name,                                    % Id       = internal id
                    {netmon_instance,start_link,Args},       % StartFun = {M, F, A}
                    transient,                               % Restart  = permanent | transient | temporary
                    2000,                                    % Shutdown = brutal_kill | int() >= 0 | infinity
                    worker,                                  % Type     = worker | supervisor
                    []                                       % Modules  = [Module] | dynamic
                },
    supervisor:start_child(netmon_instance_sup, ChildSpec);
start_monitor(Other) ->
    throw({error, ?FMT("Invalid monitor spec: ~p", [Other])}).
    
%%----------------------------------------------------------------------
%% This is the entry module for your application. It contains the
%% start function and some other stuff. You identify this module
%% using the 'mod' attribute in the .app file.
%%
%% The start function is called by the application controller.
%% It normally returns {ok,Pid}, i.e. the same as gen_server and
%% supervisor. Here, we simply call the start function in our supervisor.
%% One can also return {ok, Pid, State}, where State is reused in stop(State).
%%
%% Type can be 'normal' or {takeover,FromNode}. If the 'start_phases'
%% attribute is present in the .app file, Type can also be {failover,FromNode}.
%% This is an odd compatibility thing.
%% @private
%%----------------------------------------------------------------------
start(_Type, _Args) ->
    case supervisor:start_link({local, ?MODULE}, ?MODULE, []) of
    {ok, Pid} ->
        %% Start requested monitors
        [start_monitor(Args) || Args <- get_node_opts(lama:get_app_env(netmon, monitors, []))],
        {ok, Pid};
    Error ->
        Error
    end.

%%----------------------------------------------------------------------
%% stop(State) is called when the application has been terminated, and
%% all processes are gone. The return value is ignored.
%% @private
%%----------------------------------------------------------------------
stop(_S) ->
    ok.

%%----------------------------------------------------------------------
%% @spec (Options) -> Opts
%%          Options = [{Nodes, Opts}]
%%          Nodes   = node() | [node()] | extra_db_nodes
%%          Opts    = [tuple()]
%% @doc Fetch configuration option from list for the current node.
%% @end
%%----------------------------------------------------------------------
get_node_opts(Options) ->
    case [Opts || {Node, Opts} <- Options, node_has_monitors(Node)] of
    [Opt] -> Opt;
    []    -> []
    end.
    
node_has_monitors(Nodes) when Nodes =:= node() ->
    true;
node_has_monitors(Nodes) when is_list(Nodes) ->
    lists:member(node(), Nodes);
node_has_monitors(_) ->
    false.

%%%---------------------------------------------------------------------
%%% Supervisor behaviour callbacks
%%%---------------------------------------------------------------------

%% @private
init([]) ->
    {MaxR, MaxT} = lama:get_app_env(netmon, max_restart_frequency, {2, 5}),
    EchoAddr     = lama:get_app_env(netmon, echo_addr, {0,0,0,0}),
    EchoPort     = lama:get_app_env(netmon, echo_port, 64000),
    PortMap      = lama:get_app_env(netmon, port_map, []),
    MnesiaGuard  = lama:get_app_env(netmon, mnesia_guard, []),
    MCast        = case lama:get_app_env(netmon, multicast, undefined) of
                   undefined -> [];
                   MCastAddr -> [{multicast, MCastAddr}]
                   end,
    MnesiaGuardSpec = 
        case MnesiaGuard of
        [] -> [];
        _  -> [get_mnesia_guard_spec(MnesiaGuard)]
        end,

    try
        case get_node_opts(lama:get_app_env(netmon, monitors, [])) of
        [] -> throw(ignore);
        _  -> ok
        end,

        {ok,
            {_SupFlags = {one_for_one, MaxR, MaxT},
                [
                  % Netmon UDP/TCP socket owner
                  {   netmon,                                  % Id       = internal id
                      {netmon,start_link,                      % StartFun = {M, F, A}
                          [ [{echo_addr, EchoAddr}, {echo_port, EchoPort}, {port_map, PortMap}] ++ MCast ]},
                      permanent,                               % Restart  = permanent | transient | temporary
                      2000,                                    % Shutdown = brutal_kill | int() >= 0 | infinity
                      worker,                                  % Type     = worker | supervisor
                      [netmon]                                 % Modules  = [Module] | dynamic
                  }
                ]
                ++ MnesiaGuardSpec ++ 
                [
                  % Supervisor of netmon_instance's
                  {   netmon_instance_sup,
                      {supervisor,start_link,
                          [{local, netmon_instance_sup}, ?MODULE, {netmon_instance_sup, MaxR, MaxT}]},
                      permanent,                               % Restart  = permanent | transient | temporary
                      infinity,                                % Shutdown = brutal_kill | int() >= 0 | infinity
                      supervisor,                              % Type     = worker | supervisor
                      [netmon]                                 % Modules  = [Module] | dynamic
                  }
                ]
            }
        }
    catch _:ignore ->
        ignore
    end;

init({netmon_instance_sup, MaxR, MaxT}) ->
    %% Start an empty supervisor. Children are added dynamically ('transient' restart means that they'll
    %% only be auto-restarted if they terminate abrormally with reason other than 'normal').
    {ok, {_SupFlags = {one_for_one, MaxR, MaxT}, []}}.

get_mnesia_guard_spec(Options) ->
    {   netmon_mnesia,                          % Id       = internal id
        {netmon_mnesia, start_link, [Options]}, % StartFun = {M, F, A}
        permanent,                              % Restart  = permanent | transient | temporary
        2000,                                   % Shutdown = brutal_kill | int() >= 0 | infinity
        worker,                                 % Type     = worker | supervisor
        [netmon_mnesia]                         % Modules  = [Module] | dynamic
    }.

