-module(mod_mt_router).
-behaviour(gen_mod).

-export([start/2, read_packet/1, stop/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-record(amqp_params_network, {username           = <<"ejabberd">>,
                              password           = <<"magictiger">>,
                              virtual_host       = <<"msg_server">>,
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
			      durable = true, 
			      auto_delete = false, 
			      internal = false, 
			      nowait = false, 
			      arguments = []} ).

-record('queue.declare', { ticket = 0, 
			   queue = <<"">>, 
			   passive = false, 
			   durable = true, 
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

-record('basic.publish', { ticket = 0, 
			   exchange = <<"">>,
			   routing_key = <<"">>, 
			   mandatory = false, 
			   immediate = false}).

-record('P_basic', { content_type, 
		     content_encoding, 
		     headers, 
		     delivery_mode, 
		     priority, 
		     correlation_id, 
		     reply_to, 
		     expiration, 
		     message_id, 
		     timestamp, 
		     type, 
		     user_id, 
		     app_id, 
		     cluster_id}).

-record(amqp_msg, { props = #'P_basic'{delivery_mode = 2}, 
		    payload = <<>>}).

start(Host, Opts) ->
  ejabberd_hooks:add(filter_packet, global,
      ?MODULE, read_packet, 50),
  ?INFO_MSG("Starting AMQP client", []),
  get_rabbitmq_client(),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(filter_packet, global, ?MODULE,
      read_packet, 50),
  %% Hoax of a value.
  State = <<"Stop">>,
  amqp_client:stop(State),
  ?INFO_MSG("Stopping AMQP client", []),
  ok.

read_packet({From, To, Packet}) ->
    %% {To, From, Packet}.
    MtRouted = xml:get_tag_attr_s(<<"mt_routed">>, Packet),
    case MtRouted of 
	<<"true">> ->
		{From, To, Packet};
	_ ->
    		case prepare_message_for_rabbitmq({From, To, Packet}) of
			{ok, queued_to_rabbitmq, QueueMessage} ->
				push_message_to_queue(QueueMessage),
				drop;
			{ok, routed_message, RoutedPacket} ->
				{From, To, Packet};
			{ok, iq_message} ->
				{From, To, Packet};
			{ok, presence} ->
				{From, To, Packet}
    		end
    end.

prepare_message_for_rabbitmq(FromToPacket) ->
    {From, To, Packet} = FromToPacket,
    ?INFO_MSG("mod_mt_router a package has been sent coming from: ~p", [From]),
    ?INFO_MSG("mod_mt_router a package has been sent to: ~p", [To]),
    ?INFO_MSG("mod_mt_router a package has been sent with the following packet: ~p",     [Packet]),
    Fuser = From#jid.luser,
    Fdomain = From#jid.lserver,
    Fresource = From#jid.lresource,
    Tuser = To#jid.luser,
    Tdomain = To#jid.lserver,
    Tresource = To#jid.lresource,
    {_, Name, _, MList} = Packet,
    Mid = xml:get_tag_attr_s(<<"id">>, Packet),
    ?INFO_MSG("mod_mt_router MID is ~p", [Mid]),


    case Name of 
	<<"message">> ->
		?INFO_MSG("FUSER ~p~n", [Fuser]),
		?INFO_MSG("FDOMAIN ~p~n", [Fdomain]),
		?INFO_MSG("FRESOURCE ~p~n", [Fresource]),
		?INFO_MSG("TUSER ~p~n", [Tuser]),
		?INFO_MSG("TDOMAIN ~p~n", [Tdomain]),
		?INFO_MSG("TRESOURCE ~p~n", [Tresource]),
		?INFO_MSG("MID ~p", [Mid]),
		BodyXmlObj = xml:get_subtag(Packet, <<"body">>),
		SentOnXmlObj = xml:get_subtag(Packet, <<"sent_on">>),
		SentOn = case SentOnXmlObj of false -> false; _ -> xml:get_tag_attr_s(<<"sent_on">>, SentOnXmlObj) end,
		Body = case BodyXmlObj of false -> false; _ -> xml:get_subtag_cdata(Packet, <<"body">>) end,
		ChatXmlObj = xml:get_subtag(Packet, <<"chat_thread">>),
		Chat = case ChatXmlObj of false -> false; _ -> xml:get_tag_attr_s(<<"id">>, ChatXmlObj) end,
		ReceivedXmlObj = xml:get_subtag(Packet, <<"received">>),
		Received = case ReceivedXmlObj of false -> false; _ -> xml:get_tag_attr_s(<<"id">>, ReceivedXmlObj) end,
		DisplayedXmlObj = xml:get_subtag(Packet, <<"displayed">>),
		Displayed = case DisplayedXmlObj of false -> false; _ -> xml:get_tag_attr_s(<<"id">>, DisplayedXmlObj) end,
		MsgType = get_message_type(ReceivedXmlObj, DisplayedXmlObj, BodyXmlObj),
		QueueMessageMap = #{<<"from_user">> => Fuser,
				    <<"from_domain">>=> Fdomain,
				    <<"from_resource">> => Fresource,
				    <<"to_user">> => Tuser,
				    <<"to_domain">> => Tdomain,
				    <<"to_resource">> => Tresource,
				    <<"mid">> => Mid,
				    <<"body">> => Body,
				    <<"received">> => Received,
				    <<"displayed">> => Displayed,
				    <<"chat_thread">> => Chat,
				    <<"sent_on">> => SentOn,
				    <<"type">> => MsgType
		},
		Pred = fun(K,V) -> not is_boolean(V) end,
		QueueMessage = jiffy:encode(maps:filter(Pred, QueueMessageMap)),
		?INFO_MSG("BODY ~p", [QueueMessage]),
		{ok, queued_to_rabbitmq, QueueMessage};
	<<"iq">> ->
		{ok, iq_message};
	<<"presence">> ->
		{ok, presence}
    end.

get_message_type(ReceivedXmlObj, DisplayedXmlObj, BodyXmlObj) ->
    MessageTypeMap = #{<<"jabber_msg">> => BodyXmlObj,
		       <<"jabber_msg_displayed">> => DisplayedXmlObj,
		       <<"jabber_msg_received">> => ReceivedXmlObj
    },
    Pred = fun(K,V) -> not is_boolean(V) end,
    hd(maps:keys(maps:filter(Pred, MessageTypeMap))).
    


push_message_to_queue(MessageStrList) ->
    ?INFO_MSG("MSG JSON ~p~n", [jiffy:encode(MessageStrList)]),
    {ok, RabbitConnection} = get_rabbitmq_client(),
    {ok, Channel} = amqp_connection:open_channel(RabbitConnection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"sender_receiver">>}),
    amqp_channel:call(Channel, #'queue.declare'{queue = <<"EjabOutQ">>}),
    amqp_channel:call(Channel, #'queue.bind'{queue = <<"EjabOutQ">>, exchange = <<"sender_receiver">>}),
    amqp_channel:cast(Channel,
                      #'basic.publish'{
                        exchange = <<"sender_receiver">>,
                        routing_key = <<"EjabOutQ">>},
                      #amqp_msg{payload = MessageStrList}),
    ok = amqp_channel:close(Channel),
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
		
