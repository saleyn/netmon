%%%------------------------------------------------------------------------
%%% File: $Id$
%%%------------------------------------------------------------------------
%%% @doc Network Node Monitor
%%% @author Serge Aleynikov <saleyn@gmail.com>
%%% @version {@vsn}
%%% @end
%%%------------------------------------------------------------------------
%%% Created: 2007-01-10 by Serge Aleynikov <saleyn@gmail.com>
%%% $URL$
%%%------------------------------------------------------------------------
-module(netmon).
-author('saleyn@gmail.com').

-behaviour(gen_server).

%% External exports
-export([start_link/1, add_monitor/6, add_monitor/7, del_monitor/1, 
         ip_to_str/1, ip_to_str/2, nodes_to_ips/1]).

%% Internal exports
-export([send_ping/5, state/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include("netmon.hrl").
-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/inet.hrl").

-record(state, {
    version,       % Module version extracted from -vsn() attribute.
    socket,        % Echo UDP socket
    tcp_listener,  % TCP Listener socket for incoming ECHO connections.
    echo_addr,     % ip_address() - netif to use when sending ECHO packets.
    echo_port,     % integer() - port to use when sending/receiving ECHO packets.
    tcp_timeout,   % TCP connect timeout for TCP pings.
    accept_ref,    % Reference of call to asyncronous accept.
    tcp_clients,   % List of connected TCP ECHO clients.
    port_map,      % [ {node(), UdpPort::integer()} ]  - exception list of UDP ports
    start_time,    % Application's startup time in now() format
    rev            % Revision of this module
}).

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @spec (Options) -> {ok, Pid} | {error, Reason}
%%          Options = [ Option ]
%%          Option  = {echo_addr, IP::ip_address()} |
%%                    {echo_port, Port::integer()} |
%%                    {multicast, IP::ip_address()}
%% @doc Start a network monitoring agent.  It will listen for UDP pings
%%      on a given interface/port.  If multicast IP is given, the process
%%      will join the multicast group.
%% @end
%%-------------------------------------------------------------------------
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

%%-------------------------------------------------------------------------
%% @equiv add_monitor(Name, App, Type, Nodes, Notify, Interval, udp)
%% @doc This function starts a process monitoring `Nodes'.
%% @see add_monitor/7
%% @end
%%-------------------------------------------------------------------------
add_monitor(Name, App, Type, Nodes, Notify, Interval) ->
    add_monitor(Name, App, Type, Nodes, Notify, Interval, udp).

%%-------------------------------------------------------------------------
%% @equiv netmon_instance:start_link(Name, App, Type, Nodes, Notify, 
%%          Interval, PingType)
%% @doc This function starts a process monitoring `Nodes'.
%% @see netmon_instance:start_link/7
%% @end
%%-------------------------------------------------------------------------
add_monitor(Name, App, Type, Nodes, _Notify = {M, F}, Interval, PingType) ->
    netmon_app:start_monitor({Name, App, Type, Nodes, {M, F}, Interval, PingType}).

%%-------------------------------------------------------------------------
%% @spec (Name) -> ok | {error, not_running}
%% @doc Shuts down a monitor `Name' process.
%% @end
%%-------------------------------------------------------------------------
del_monitor(Name) ->
    case whereis(Name) of
    Pid when is_pid(Pid) ->
        exit(Pid, shutdown),
        ok;
    undefined ->
        {error, not_running}
    end.

%%-------------------------------------------------------------------------
%% @spec (Method, NodeIPs, MonitorName::atom(), App::atom(), 
%%          StartTime::now()) -> ok
%%              Method  = udp | tcp
%%              NodeIPs = [ {node(), ip_address()} ]
%% @private
%%-------------------------------------------------------------------------
send_ping(Method, NodeIPs, MonitorName, App, StartTime) ->
    ID     = random:uniform((1 bsl 27)-1),
    Packet = #ping_packet{
        name       = MonitorName,
        type       = ping,
        node       = node(),
        app        = App,
        start_time = StartTime,
        id         = ID
    },
    ok = gen_server:call(?MODULE, {send_ping, Method, NodeIPs, Packet}),
    ID.

%%-------------------------------------------------------------------------
%% @spec () -> {ok, [ {Option::atom(), Value} ]}
%% @doc Return internal server state
%% @end
%%-------------------------------------------------------------------------
state() ->
    gen_server:call(?MODULE, state).

%%-------------------------------------------------------------------------
%% @spec (IP) -> string()
%%         IP = ip_address() | string() | socket()
%% @doc Formats IP address as "XXX.YYY.ZZZ.NNN" or "XXX.YYY.ZZZ.NNN:MMMMM"
%%      if IP is a `socket()'.
%% @end
%%-------------------------------------------------------------------------
ip_to_str({_,_,_,_}=IP) ->
    inet_parse:ntoa(IP);
ip_to_str(IP) when is_list(IP) ->
    IP;
ip_to_str(Sock) when is_port(Sock) ->
    {ok, {Addr, Port}} = inet:sockname(Sock),
    ip_to_str(Addr, Port).

%%-------------------------------------------------------------------------
%% @spec (IP, Port::integer()) -> string()
%%         IP = ip_address() | string()
%% @doc Formats IP:Port address as "XXX.YYY.ZZZ.NNN:MMMMM"
%% @end
%%-------------------------------------------------------------------------
ip_to_str({I1,I2,I3,I4}, Port) ->
    ?FMT("~w.~w.~w.~w:~w", [I1,I2,I3,I4,Port]);
ip_to_str(IP, Port) when is_list(IP) ->
    ?FMT("~s:~w", [IP,Port]).

%%----------------------------------------------------------------------
%% @spec nodes_to_ips(Nodes) -> [ {node(), IP::string()} ]
%%          Nodes = [ node() ]
%% @doc Converts a list of node names to a list of IP addresses.
%%      Error is thrown if a node corresponds to unknown host.
%% @end
%%----------------------------------------------------------------------
nodes_to_ips(Nodes) ->
    F = fun(N) ->
        case net_kernel:node_info(N, address) of
        {ok, #net_address{address={Addr, _}}} ->
            Addr;
        {error, _} ->
            Host = string:sub_word(atom_to_list(N), 2, $@),
            case inet:gethostbyname(Host, inet) of
            {ok, #hostent{h_addr_list=[IP | _Rest]}} ->
                IP;
            {error, Reason} ->
                exit(?FMT("Can't resolve host: ~s. Reason: ~p", [Host, Reason]))
            end
        end
    end,
    [{N, F(N)} || N <- Nodes].

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
init([Options]) ->
    try
        PMap    = proplists:get_value(port_map,    Options, []),
        MCast   = proplists:get_value(multicast,   Options),
        Addr    = proplists:get_value(echo_addr,   Options, {0,0,0,0}),
        DefPort = proplists:get_value(echo_port,   Options),
        TcpTout = proplists:get_value(tcp_timeout, Options, 2000),
        Port    = case lists:keysearch(node(), 1, PMap) of
                  {value, {_, P}} -> P;
                  false           -> DefPort
                  end,

        case Addr of
        Addr when is_list(Addr) ->
            {ok, IP} = inet_parse:ipv4_address(Addr);
        IP ->
            ok
        end,

        case MCast of
        undefined -> Multicast = [];
        MAddr     -> Multicast = [{add_membership, {MAddr, IP}}]
        end,

        Rev =   try re:replace(
                        proplists:get_value(vsn, module_info(attributes), ["1.0"]),
                        "[^0-9\.]+", [], [{return, list}]) of
                L when is_list(L), L =/= [] ->
                    L
                catch _:_ ->
                    "1.0"
                end,

        IPstr = ip_to_str(IP, Port),
        
        % Open a UDP socket used for ECHO pings
        case gen_udp:open(Port, [binary, {reuseaddr, true}, {ip, IP}, {active, once}] ++ Multicast) of
        {ok, Sock} ->
            error_logger:info_msg("Opened netmon UDP listener on ~s\n", [IPstr]);
        {error, Error} ->
            Sock = undefined,
            throw({error, ?FMT("Cannot open UDP port (~s): ~s\n", [IPstr, inet:format_error(Error)])})
        end,

        % Open a TCP socket used for ECHO pings
        case gen_tcp:listen(Port, [binary, {reuseaddr, true}, {ip, IP}, {active, once}]) of
        {ok, LSock} ->
            error_logger:info_msg("Opened netmon TCP listener on ~s\n", [IPstr]),
            {ok, LRef} = prim_inet:async_accept(LSock, -1),

            {ok, #state{socket=Sock, echo_addr=IP, echo_port=DefPort,
                        accept_ref=LRef, tcp_listener=LSock,
                        port_map=PMap, start_time=now(), rev=Rev,
                        tcp_timeout=TcpTout, tcp_clients=[]}};
        {error, Why} ->
            throw({error, ?FMT("Cannot start TCP listener (~s): ~s\n", [IPstr, inet:format_error(Why)])})
        end

    catch _:Err ->
        {stop, Err}
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
handle_call({send_ping, Method, NodeIPs, #ping_packet{} = Packet}, _From,
            #state{echo_port=DefPort, port_map=PMap, rev=Rev} = State) ->
    PacketB = term_to_binary(Packet#ping_packet{version=Rev, sent_time=now()}),
    F = fun({N, IP}) ->
            Port = proplists:get_value(N, PMap, DefPort),
            do_send_ping(Method, State, IP, Port, PacketB)
        end,
    [ F(NodeIP) || NodeIP <- NodeIPs ],
    {reply, ok, State};

handle_call(state, _From, #state{echo_addr=Addr, echo_port=P, port_map=PMap, start_time=T, 
                                 socket=S, tcp_listener=L, accept_ref=A, tcp_clients=C} = State) ->
    Reply = [{echo_addr, Addr}, {echo_port,P}, {port_map,PMap}, {start_time,T}, 
             {udp_sock, inet:sockname(S)}, {tcp_sock, inet:sockname(L)},
             {accept_ref, A}, {tcp_clients, C}],
    {reply, {ok, Reply}, State};

handle_call(Request, _From, _State) ->
    {stop, {not_implemented, Request}}.

do_send_ping(udp, State, IP, Port, PacketB) ->
    gen_udp:send(State#state.socket, IP, Port, PacketB);
do_send_ping(tcp, State, IP, Port, PacketB) ->
    NetIF = State#state.echo_addr,
    Tout  = State#state.tcp_timeout,
    % Don't block the main server process
    spawn(fun() ->
        case gen_tcp:connect(IP, Port, [binary, {nodelay, true}, {packet, 2}, {ip, NetIF}, {active, false}], Tout) of
        {ok,    Sock} -> ok;
        {error, Sock} -> exit(normal)
        end,
        
        case gen_tcp:send(Sock, PacketB) of
        ok -> ok;
        _  -> exit(normal)
        end,
            
        case gen_tcp:recv(Sock, 0, Tout*2) of
        {ok, Reply} -> 
            case binary_to_term(Reply) of
            #ping_packet{type=pong, name=Name, app=App} = Pong ->
                error_logger:info_msg("Netmon reply to ~w ~w.\n", [Name, App]),
                netmon_instance:notify(Pong);
            Other ->
                error_logger:error_msg("Netmon - invalid TCP pong response: ~p\n", [Other])
            end;
        {error, _} ->
            ok
        end,

        exit(normal)
    end),
    ok.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% @private
%%----------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% @private
%%----------------------------------------------------------------------
handle_info({udp, Socket, IP, Port, Packet}, #state{socket=Socket} = State) ->
    do_handle_echo(udp, Socket, IP, Port, Packet, State#state.start_time),
    {noreply, State};

handle_info({tcp, Socket, Packet}, #state{tcp_clients=Clients} = State) ->
    {ok, {IP, Port}} = inet:sockname(Socket),
    do_handle_echo(tcp, Socket, IP, Port, Packet, State#state.start_time),
    % We are only expecting one ECHO message from client.
    gen_tcp:close(Socket),
    {noreply, State#state{tcp_clients = (Clients -- [Socket])}};

handle_info({tcp_closed, Socket}, #state{tcp_clients=Clients} = State) ->
    {noreply, State#state{tcp_clients = (Clients -- [Socket])}};
    
handle_info({tcp_error, Socket, _Reason}, #state{tcp_clients=Clients} = State) ->
    {noreply, State#state{tcp_clients = (Clients -- [Socket])}};
    
%% New incoming TCP connection
handle_info({inet_async, ListSock, Ref, {ok, CliSocket}},
            #state{tcp_listener=ListSock, accept_ref=Ref, tcp_clients=CliSocks} = State) ->
    true = inet_db:register_socket(CliSocket, inet_tcp),
    {ok, NewRef} = prim_inet:async_accept(ListSock, -1),
    % Passively wait for one ECHO message.
    inet:setopts(CliSocket, [{nodelay, true}, binary, {active, once}, {packet, 2}]),
    {noreply, State#state{accept_ref=NewRef, tcp_clients=[CliSocket | CliSocks]}};

handle_info({inet_async, ListSock, Ref, Error}, #state{tcp_listener=ListSock, accept_ref=Ref} = State) ->
    error_logger:error_msg("Netmon - error in socket acceptor: ~p.\n", [Error]),
    {stop, Error, State};

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
terminate(_Reason, #state{tcp_clients=Clients}) ->
    [gen_tcp:close(C) || C <- Clients],
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

do_handle_echo(Proto, Socket, IP, Port, Packet, StartTime) ->
    inet:setopts(Socket, [{active, once}]),
    case catch binary_to_term(Packet) of
    #ping_packet{type=ping, app=App, node=Node} = Ping ->
        error_logger:info_msg("Netmon ~w ping from ~w (~w): ~s\n",
            [Proto, Node, App, ip_to_str(IP, Port)]),
        netmon_instance:notify(Ping),
        Reply = Ping#ping_packet{type=pong, node=node(), start_time=StartTime},
        case Proto of
        udp -> ok = gen_udp:send(Socket, IP, Port, term_to_binary(Reply));
        tcp -> ok = gen_tcp:send(Socket, term_to_binary(Reply))
        end;
    #ping_packet{type=pong, app=App, node=Node} = Pong when Proto =:= udp ->
        % Only UDP pongs arrive here.  TCP pongs are handled by do_send_ping()
        error_logger:info_msg("Netmon ~w echo from ~w (~w): ~s\n",
            [Proto, Node, App, ip_to_str(IP, Port)]),
        netmon_instance:notify(Pong);
    _ ->
        ok
    end.

