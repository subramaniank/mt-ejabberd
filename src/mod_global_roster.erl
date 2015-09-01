-module(mod_global_roster).

-behavior(gen_mod).

-include("ejabberd.hrl").
-include("logger.hrl").
-export([start/2, stop/1, on_presence_joined/4, on_presence_left/4]).

start(Host, _Opts) ->
  ?INFO_MSG("mod_global_roster starting", []),
  ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, on_presence_joined, 50),
  ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, on_presence_left, 50),
  ok.

stop(Host) ->
  ?INFO_MSG("mod_global_roster stopping", []),
  ejabberd_hooks:remove(set_presence_hook, Host, ?MODULE, on_presence_joined, 50),
  ejabberd_hooks:remove(unset_presence_hook, Host, ?MODULE, on_presence_left, 50),
  ok.
  
on_presence_joined(User, Server, _Resource, _Packet) ->
  {ok, Client} = client(Server),
  eredis:q(Client, ["SET", User, 1]),
  eredis:q(Client, ["EXPIRE", User, 86400]),
  eredis:q(Client, ["PUBLISH", "ejabberd-activity", lists:concat(["{'p_id': '",binary_to_list(User),"','state':'online'}"])]),
  none.

on_presence_left(User, Server, _Resource, _Status) ->
  {ok, Client} = client(Server),
  eredis:q(Client, ["DEL", User]),
  eredis:q(Client, ["PUBLISH", "ejabberd-activity", lists:concat(["{'p_id': '",binary_to_list(User),"','state':'offline'}"])]),
  none.

redis_host(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE, redis_host, fun(A) -> binary_to_list(A) end, "127.0.0.1").

redis_port(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE, redis_port, fun(A) -> A end, 6379).

redis_db(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE, redis_db, fun(A) -> A end, 0).

client(Server) ->
  case whereis(eredis_driver) of
    undefined ->
      case eredis:start_link(redis_host(Server), redis_port(Server), redis_db(Server)) of
        {ok, Client} ->
          register(eredis_driver, Client),
          {ok, Client};
        {error, Reason} ->
          {error, Reason}
      end;
    Pid ->
      {ok, Pid}
  end.
%% TODO
%% Handle redis errors
%% Handle redis returning 0 (if item is in set or cannot be removed)
