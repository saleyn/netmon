%%%------------------------------------------------------------------------
%%% File: $Id$
%%%------------------------------------------------------------------------
%%% Created: 2007-01-10 by Serge Aleynikov <saleyn@gmail.com>
%%% $URL$
%%%------------------------------------------------------------------------

-record(ping_packet, {
      version               % string() - netmon version.
    , name                  % atom()  - name of the netmon_instance sending request
    , type                  % ping | pong      - ping=request, pong=reply
    , node                  % FromNode::node()
    , app                   % FromApp::atom()
    , start_time            % now()   - start time of the pinging/replying node
    , sent_time             % now()   - sent time of the packet
    , id                    % Some unique transaction id
}).

-record(mon_notify, {
      name                  % Monitor's name
    , action                % node_up | node_down | ping | pong
    , node                  % Node name
    , node_start_time       % Start time of the `node' (if known from the last ping packet)
    , details               % #ping_packet{} when action is 'ping' | 'pong'
                            % or `Info' when action is node_up | node_down
    , up_nodes              % Up nodes
    , down_nodes            % Down nodes
    , watch_nodes           % Nodes to watch for connectivity
    , start_time            % Start time of current node
}).

-ifndef(FMT).
-define(FMT(F, A), lists:flatten(io_lib:format(F, A))).
-endif.
