%%%------------------------------------------------------------------------
%%% @doc Network Node Monitor.  This module monitors connectivity to a list
%%%      of nodes.  When connectivity is lost it starts pinging the
%%%      disconnected nodes until the ping message is echoed back and
%%%      connectivity is restored.
%%% @author Serge Aleynikov <saleyn@gmail.com>
%%% @version {@vsn}
%%% @end
%%%------------------------------------------------------------------------
%%% Created: 2007-01-10 by Serge Aleynikov <saleyn@gmail.com>
%%% $Header$
%%%------------------------------------------------------------------------
-module(netmon_instance).
-author('saleyn@gmail.com').

-behaviour(gen_server).

%% External exports
-export([start_link/7]).

%% Internal exports
-export([notify/1, state/1, test_notify/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include("netmon.hrl").

-record(state, {
    watch_nodes,      % List of nodes to watch for connectivity
    dead_nodes,       % List of disconnected nodes from the watch_nodes list
    app,              % Application interested in monitoring watch_nodes
    type,             % any | all
    notify_mf,        % {M, F} callback to call on node_up | node_down | node_ping
    timer,
    ping_timeout,     % in milliseconds
    start_time,       % Process start time
    ping_type,        % What ping type to use (udp | tcp | net_adm | passive)
    ips,              % List of resolved {Node, IP} pairs
    lastid,           % ID sent in the last Ping request packet
    start_times       % dict() of Key=node(), Data=StartTime::now()
}).

-define(NOTIFY_ARITY, 1).

%%-------------------------------------------------------------------------
%% @spec (Name, App, Type, Nodes, Notify, Interval, PingType) -> ok | {error, Reason}
%%         Name        = atom()
%%         App         = atom()
%%         Type        = any | all
%%         Nodes       = [ node() ]
%%         Notify      = {M, F}
%%         Interval    = integer()
%%         PingType    = udp | tcp | net_adm | passive
%% @doc This function adds a monitor of `Nodes'.
%%      <dl>
%%      <dt>Type</dt>
%%          <dd>Controls whether loss of any/all nodes in the `Nodes' group will
%%               result in the call to `Notify'.</dd>
%%      <dt>Nodes</dt>
%%          <dd>List of nodes to watch for connectivity.</dd>
%%      <dt>App</dt>
%%          <dd>Application name starting the monitor instance.</dd>
%%      <dt>Interval</dt>
%%          <dd>Ping interval in seconds (ping is activated on detecting
%%              connection loss).</dd>
%%      <dt>PingType</dt>
%%          <dd>Controls whether to use UDP pings, net_adm:ping/1 calls
%%              or be passive (rely on the peer to establish communication).
%%              The later is useful is connectivity to Nodes is protected by
%%              a firewall.</dd>
%%      <dt><a name="notify">Notify</a></dt>
%%          <dd>Is a `M:F/1' function that takes #mon_notify{} parameter:
%%      ```
%%          #mon_notify{name=Monitor::atom(), action=Action, node=Node::node(), 
%%                  node_start_time=NodeST, Details, UpNodes::nodes(), 
%%                  DnNodes::nodes(), WatchNodes::nodes(), StartTime::now()} ->
%%                      Result
%%              Result  = {ignore,  NewWatchNodes} |
%%                        {connect, NewWatchNodes} |
%%                        stop                     |
%%                        shutdown                 |
%%                        restart
%%              Action  = node_up | node_down | ping | pong
%%              Details = #ping_packet{} (when Action = ping    | pong)
%%                      | InfoList       (when Action = node_up | node_down)
%%              NodeST  = now() | undefined
%%      '''
%%      Arguments given in the `Notify' callback are:
%%      <dl>
%%      <dt>Monitor</dt>
%%          <dd>Name of the monitor instance (from the first argument of
%%              netmon:add_monitor/7.</dd>
%%      <dt>Node</dt>
%%          <dd>Node that caused node_up/node_down/pong event.</dd>
%%      <dt>Event</dt>
%%          <dd>`node_up'   - a new connection from Node is detected.</dd>
%%          <dd>`node_down' - a loss of connection from Node is detected.</dd>
%%          <dd>`ping'      - a ping request from a peer node</dd>
%%          <dd>`pong'      - an echo reply to a TCP/UDP ping is received
%%                            from Node.</dd>
%%      <dt>Details</dt>
%%          <dd>`#ping_packet{}' - for `pong' events.</dd>
%%          <dd>`InfoList' - for `node_up' and `node_down' events.
%%              See //kernel/net_kernel:monitor_node/1.</dd>
%%      <dt>UpNodes</dt>
%%          <dd>List of connected nodes from the `WatchNodes' list.</dd>
%%      <dt>DownNodes</dt>
%%          <dd>List of disconnected nodes from the `WatchNodes' list.</dd>
%%      <dt>WatchNodes</dt>
%%          <dd>List of nodes to watch for connectivity.</dd>
%%      <dt>NodeST</dt>
%%          <dd>Time when this monitor was started on `Node'.</dd>
%%      <dt>StartTime</dt>
%%          <dd>Time when this monitor was started on current node.</dd>
%%      </dl>
%%      </dd>
%%      </dl>
%% @end
%%-------------------------------------------------------------------------
start_link(Name, App, Type, Nodes, _Notify = {M, F}, Interval, PingType) when
    (Type =:= any orelse Type =:= all), 
    is_list(Nodes), is_integer(Interval),
    (PingType =:= udp orelse PingType =:= tcp orelse
     PingType =:= net_adm orelse PingType =:= passive)
->
    gen_server:start_link(
        {local, Name}, ?MODULE, [App, Type, Nodes, {M, F}, Interval, PingType], []).

%%-------------------------------------------------------------------------
%% @spec (Name::pid()) -> [ {Option::atom(), Value} ]
%% @doc Get internal server state.  Useful for debugging.
%% @end
%%-------------------------------------------------------------------------
state(Name) ->
    gen_server:call(Name, state).

%%-------------------------------------------------------------------------
%% @spec (Ping::#ping_packet{}) -> ok
%% @doc Notify a monitor of a UDP ping/pong message sent/echoed by 
%%      another node.  Called from the `netmon' module.
%% @end
%% @private
%%-------------------------------------------------------------------------
notify(#ping_packet{name=Name} = Ping) ->
    gen_server:cast(Name, Ping).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

%%-----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% @private
%%-----------------------------------------------------------------------
init([App, Type, Nodes, {M,F} = Notify, Interval, PingType]) ->
    try
        {module, M} =:= code:ensure_loaded(M) orelse
            exit(?FMT("Module ~w not loaded!", [M])),

        erlang:function_exported(M, F, ?NOTIFY_ARITY) orelse
            exit(?FMT("Function ~w:~w/~w not exported!", [M, F, ?NOTIFY_ARITY])),
        
        {A1,A2,A3} = Now = now(),
        random:seed(A1, A2, A3),
        case PingType of
        passive -> ok;
        _       -> self() ! ping_timer
        end,

        net_kernel:monitor_nodes(true, [{node_type, visible}, nodedown_reason]),
        WNodes = Nodes -- [node()],
        DNodes = WNodes -- nodes(connected),
        State = #state{app=App, type=Type, watch_nodes=WNodes, dead_nodes=DNodes,
                       lastid=0, ips=netmon:nodes_to_ips(WNodes), notify_mf=Notify, 
                       start_time=Now, ping_timeout=Interval*1000, ping_type=PingType,
                       start_times=dict:new()},
        {ok, State}
    catch exit:Why ->
        {stop, Why}
    end.

%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%% @private
%%----------------------------------------------------------------------
handle_call(state, _From, State) ->
    Reply = [{watch_nodes, State#state.watch_nodes},
             {dead_nodes,  State#state.dead_nodes},
             {type,        State#state.type},
             {start_time,  State#state.start_time},
             {notify_mf,   State#state.notify_mf}],
    {reply, Reply, State};

handle_call(Request, _From, _State) ->
    {stop, {not_implemented, Request}}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% @private
%%----------------------------------------------------------------------

handle_cast(#ping_packet{type=PingOrPong, node=FromNode, app=App, id=ID} = PingPacket,
            #state{watch_nodes=WNodes, dead_nodes=DNodes, app=App, lastid=ID} = State) 
  when PingOrPong =:= ping; PingOrPong =:= pong ->
    case {lists:member(FromNode, nodes(connected)), lists:member(FromNode, DNodes)} of
    {false, true} ->
        % UDP ping response from a disconnected node that we are supposed to monitor.
        % Maybe a case of partitioned network or a restart of FromNode.
        UpNodes = up_nodes(WNodes),
        MyName  = element(2, process_info(self(), registered_name)),
        Args    = {MyName, FromNode, PingOrPong, PingPacket, UpNodes, DNodes, WNodes},
        do_check_notify(PingOrPong, length(UpNodes), Args, State);
    _ ->
        % We are not interested in this node
        {noreply, State}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% @private
%%----------------------------------------------------------------------
handle_info(ping_timer, #state{dead_nodes=[]} = State) ->
    {noreply, State};
handle_info(ping_timer, #state{type=any, dead_nodes=DNodes} = State) ->
    {ID, Ref} = send_ping(DNodes, State),
    {noreply, State#state{lastid=ID, timer=Ref}};
handle_info(ping_timer, #state{type=all, watch_nodes=W, dead_nodes=D} = State)
  when length(D) =:= length(W) ->
    {ID, Ref} = send_ping(D, State),
    {noreply, State#state{lastid=ID, timer=Ref}};
handle_info(ping_timer, #state{type=all} = State) ->
    {noreply, State};

%% Established communication with Node
handle_info({nodeup, Node, Info},
            #state{watch_nodes=WNodes, dead_nodes=DNodes} = State) ->
    case {lists:member(Node, WNodes), lists:member(Node, DNodes)} of
    {false, _} ->
        {noreply, State};
    {true, false} ->
        {noreply, State};
    {true, true} ->
        UpNodes   = up_nodes(WNodes),
        NewDNodes = (DNodes -- UpNodes) -- [Node],
        MyName    = element(2, process_info(self(), registered_name)),
        Msg       = {MyName, Node, node_up, Info, UpNodes, NewDNodes, WNodes},
        do_check_notify(node_up, length(UpNodes), Msg, State#state{dead_nodes=NewDNodes})
    end;

%% Lost communication with Node
handle_info({nodedown, Node, Info},
            #state{watch_nodes=WNodes, dead_nodes=DNodes} = State) ->
    case {lists:member(Node, WNodes), lists:member(Node, DNodes)} of
    {false, _} ->
        {noreply, State};
    {true, true} ->
        {noreply, State};
    {true, false} ->
        self() ! ping_timer,
        UpNodes   = up_nodes(WNodes) -- [Node],
        NewDNodes = [Node | (DNodes -- UpNodes)],
        MyName    = element(2, process_info(self(), registered_name)),
        Msg       = {MyName, Node, node_down, Info, UpNodes, NewDNodes, WNodes},
        do_check_notify(node_down, length(UpNodes), Msg, State#state{dead_nodes=NewDNodes})
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%% @private
%%----------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%% @private
%%----------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%%---------------------------------------------------------------------
%%% Internal functions
%%%---------------------------------------------------------------------

do_check_notify(_Type, _UpNodesCount, Args, #state{type=any} = State) ->
    notify_callback(Args, State);
do_check_notify(Type, 1, Args, #state{type=all} = State)
  when Type=:=node_up; Type=:=pong ->
    notify_callback(Args, State);
do_check_notify(Type, 0, Args, #state{type=all} = State)
  when Type=:=node_down; Type=:=pong ->
    notify_callback(Args, State);
do_check_notify(_Type, _UpNodesCount, _Args, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% @spec (WatchNodes::list()) -> list()
%% @doc Build an ordered set of connected lists given an ordered set
%%      of nodes to filter.
%%----------------------------------------------------------------------
up_nodes(WatchNodes) ->
    [ N || N <- nodes(connected), lists:member(N, WatchNodes) ].

%%----------------------------------------------------------------------
send_ping(_Nodes, #state{ping_type=passive}) ->
    {0, undefined};
send_ping(Nodes, #state{ping_type=net_adm, ping_timeout=Int}) ->
    [net_adm:ping(N) || N <- Nodes],
    {0, erlang:send_after(Int, self(), ping_timer)};
send_ping(Nodes, #state{ping_type=Method, start_time=Time, app=App, ping_timeout=Int} = State) ->
    {_, Name} = process_info(self(), registered_name),
    NodeIPs = [ {N, IP} || {N, IP} <- State#state.ips, lists:member(N, Nodes) ],
    ID = netmon:send_ping(Method, NodeIPs, Name, App, Time),
    {ID, erlang:send_after(Int, self(), ping_timer)}.
    
%%----------------------------------------------------------------------
notify_callback({MonitorName, Node, Action, Details,
    UpNodes, DownNodes, WatchNodes}, #state{notify_mf={M,F}} = State)
  when Action =:= node_up; Action =:= node_down; Action =:= ping; Action =:= pong ->
    NewST  = set_node_start_time(State#state.start_times, Node, Action, Details),
    Callback = #mon_notify{
        name            = MonitorName,
        action          = Action,
        node            = Node,
        node_start_time = get_node_start_time(NewST, Node),
        details         = Details,
        up_nodes        = UpNodes,
        down_nodes      = DownNodes,
        watch_nodes     = WatchNodes,
        start_time      = State#state.start_time
    },
    NewWNodes = 
        try M:F(Callback) of
        {connect, WNodes} ->
            net_kernel:connect(Node),
            WNodes;
        {ignore, WNodes} ->
            WNodes;
        stop ->
            exit(normal);
        shutdown ->
            init:stop();
        restart ->
            init:restart();
        Other ->
            exit(?FMT("Bad return value ~w:~w/~w -> ~p", [M, F, ?NOTIFY_ARITY, Other]))
        catch _:Reason ->
            error_logger:error_msg("Netmon - execution of ~w:~w(~w)\n"
                                   "  failed with reason: ~p\n",
                [M, F, Callback, Reason]),
            exit(Reason)
        end,
    DNodes = get_dead_nodes(Action, Node, DownNodes),
    {noreply, State#state{dead_nodes=DNodes, watch_nodes=NewWNodes, start_times=NewST}}.

get_node_start_time(Dict, Node) ->
    case dict:find(Node, Dict) of
    {ok, Value} -> Value;
    error       -> undefined
    end.

set_node_start_time(Dict, Node, Action, #ping_packet{start_time=Time})
  when Action=:=ping; Action=:=pong ->
    dict:store(Node, Time, Dict);
set_node_start_time(Dict, _, _, _) ->
    Dict.

get_dead_nodes(node_up, Node, DownNodes) ->
    DownNodes -- [Node];
get_dead_nodes(node_down, Node, DownNodes) ->
    case lists:member(Node, DownNodes) of
    true  -> DownNodes;
    false -> [Node | DownNodes]
    end;
get_dead_nodes(_, _Node, DownNodes) ->
    DownNodes.

%%----------------------------------------------------------------------
%% Test functions
%%----------------------------------------------------------------------

%% @doc Sample test function that can be used in the netmon:add_monitor/7 call.
test_notify(#mon_notify{name=Monitor, node=Node, action=Action,
                        watch_nodes=WNodes, up_nodes=UpNodes, 
                        down_nodes=DownNodes, node_start_time=NST, start_time=ST})
  when Action =:= node_up; Action =:= pong ->
    io:format("NETMON (~w): ~-10w -> ~w. Up: ~w, Down: ~w (~s : ~s)\n",
              [Monitor, node_up, Node, UpNodes, DownNodes, time2str(NST), time2str(ST)]),
    case NST of
    undefined ->
        {connect, WNodes};
    _ when NST < ST ->
        %restart;
        {connect, WNodes};
    _ ->
        {connect, WNodes}
    end;
        
test_notify(#mon_notify{name=Monitor, node=Node, action=Action,
                        watch_nodes=WNodes, up_nodes=UpNodes, 
                        down_nodes=DownNodes, node_start_time=NST,
                        start_time=ST})
  when Action=:=node_down ->
    io:format("NETMON (~w): ~-10w -> ~w. Up: ~w, Down: ~w (~s : ~s)\n", 
              [Monitor, Action, Node, UpNodes, DownNodes, time2str(NST), time2str(ST)]),
    {ignore, WNodes};
test_notify(#mon_notify{action=ping, watch_nodes=WNodes}) ->
    {ignore, WNodes};
test_notify(#mon_notify{name=Monitor, node=Node, action=Action, up_nodes=UpNodes, 
                        down_nodes=DownNodes, watch_nodes=WNodes,
                        node_start_time=NST, start_time=ST}) ->
    io:format("NETMON (~w): ~-10w -> ~w. Up: ~w, Down: ~w (~w)\n", 
        [Monitor, Action, Node, UpNodes, DownNodes, NST > ST]),
    {ignore, WNodes}.

time2str({_,_,_} = Now) ->
    {{Y,Mo,D},{H,M,S}} = calendar:now_to_local_time(Now),
    io_lib:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w", [Y,Mo,D,H,M,S]);
time2str(undefined) ->
    "".
