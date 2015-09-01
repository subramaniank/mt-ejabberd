-module(mod_mt_router_listener).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-behaviour(gen_mod).

-record('basic.cancel', {consumer_tag, nowait = false}).
-record('basic.cancel_ok', {consumer_tag}).

-record('basic.deliver', {consumer_tag, delivery_tag, redelivered = false, exchange, routing_key}).

-record('basic.ack', {delivery_tag = 0, multiple = false}).

-record(amqp_params_network, {username           = <<"guest">>,
                              password           = <<"guest">>,
                              virtual_host       = <<"/">>,
                              host               = "localhost",
                              port               = undefined,
                              channel_max        = 0,
                              frame_max          = 0,
                              heartbeat          = 0,
                              connection_timeout = infinity,
                              ssl_options        = none,
                              auth_mechanisms    =
                                  [fun amqp_auth_mechanisms:plain/3,
                                   fun amqp_auth_mechanisms:amqplain/3],
                              client_properties  = [],
                              socket_options     = []}).


-record('exchange.declare', { ticket = 0,
                              exchange,
                              type = <<"direct">>,
                              passive = false,
                              durable = false,
                              auto_delete = false,
                              internal = false,
                              nowait = false,
                              arguments = []} ).

-record('queue.declare', { ticket = 0,
                           queue = <<"">>,
                           passive = false,
                           durable = false,
                           exclusive = false,
                           auto_delete = false,
                           nowait = false,
                           arguments = []} ).

-record('queue.bind', { ticket = 0,
                        queue = <<"">>,
                        exchange,
                        routing_key = <<"">>,
                        nowait = false,
                        arguments = []} ).


-record('basic.consume', {ticket = 0, queue = <<"">>, consumer_tag = <<"">>, no_local = false, no_ack = false, exclusive = false, nowait = false, arguments = []}).
-record('basic.consume_ok', {consumer_tag}).

%% gen_mod callbacks
-export([start/2,
	 start_link/2,
        stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).


-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-define(PROCNAME, mod_mt_router_listener).


start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE,
                           [Host, Opts], []).

start(Host, Opts) ->
    ?INFO_MSG("Boss this is Host ~p", [Host]),
    ?INFO_MSG("Boss these are Opts ~p", [Opts]),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                 transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    catch ?GEN_SERVER:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================


init([Host, Opts]) ->
    State = "New rabbitconsumer started",
    ?INFO_MSG("Rabbitconsumer will be started here", []),
    {ok, RabbitConnection} = get_rabbitmq_client(),
    {ok, Channel} = amqp_connection:open_channel(RabbitConnection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"plustxtExchange">>}),
    amqp_channel:call(Channel, #'queue.declare'{queue = <<"EjabInQ">>}),
    amqp_channel:call(Channel, #'queue.bind'{queue = <<"EjabInQ">>, exchange = <<"plustxtExchange">>}),
    Sub = #'basic.consume'{queue = <<"EjabInQ">>},
      #'basic.consume_ok'{consumer_tag = Tag} =
        amqp_channel:call(Channel, Sub), %% the caller is the subscriber
    {ok, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.


handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) ->
    case _Info of 
    	{'basic.consume_ok', Tag} ->
		?INFO_MSG("Basic consume_ok ~p", [Tag]);
    	{{'basic.deliver', _, _, _, Exchange, Queue}, {amqp_msg,{_,_,_,_,_,_,_,_,_,_,_,_,_,_,_},MessageStr}} ->
                MessageJson = jiffy:decode(MessageStr, [return_maps]),
		FromJid = jlib:make_jid(maps:get(<<"from_user">>, MessageJson),maps:get(<<"from_domain">>, MessageJson),maps:get(<<"from_resource">>,MessageJson)),
	 	ToJid = jlib:make_jid(maps:get(<<"to_user">>, MessageJson), maps:get(<<"to_domain">>, MessageJson),maps:get(<<"to_resource">>, MessageJson)),
		Mid = maps:get(<<"mid">>, MessageJson),
		MsgBody = maps:get(<<"body">>, MessageJson),
		XmlBody = {xmlel, <<"message">>,
     			[{<<"type">>, <<"chat">>}, {<<"id">>, Mid}, {<<"mt_routed">>,<<"true">>}],
     			[{xmlel, <<"body">>, [], [{xmlcdata, MsgBody}]}]
    		},
		?INFO_MSG("Message from ~p", [FromJid]),
		?INFO_MSG("Message to ~p", [ToJid]),
		?INFO_MSG("Message mid ~p", [Mid]),
		ejabberd_router:route(FromJid, ToJid, XmlBody)
    end,
    {noreply, State}.

terminate(_Reason, State) ->
    ok.

get_rabbitmq_client() ->
        case whereis(rabbitmq_client) of
                undefined ->
                        case amqp_connection:start(#amqp_params_network{}) of
                                {ok, Connection} ->
                                        register(rabbitmq_client, Connection),
                                        ?INFO_MSG("Got the connection really ~p", [Connection]),
                                        {ok, Connection};
                                {error, Error} ->
                                        ?ERROR_MSG("Error starting rabbitmq client ~p", [Error]),
                                        {error, Error}
                        end;
                Pid ->
                        {ok, Pid}
        end.
