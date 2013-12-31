-module(fix_test_server).
-export([start/2, stop/0, start_link/4, init/3]).
-export([handle_info/2, terminate/2]).
-export([on_fix/2]).
-include_lib("eunit/include/eunit.hrl").


start(Port, Options) ->
  application:start(ranch),
  {ok, Pid} = ranch:start_listener(fix_test_listener, 1,
    ranch_tcp, [{port, Port}],
    fix_test_server, Options
  ),
  {ok, Pid}.



-record(message, {
  type,
  seq,
  sender,
  target,
  body = []
}).


-record(fix, {
  socket,
  server_seq = 1,
  client_seq = 1,
  sender,
  on_fix,
  target
}).

on_fix(_, _) -> ok.

stop() ->
  ranch:stop_listener(fix_test_listener).


start_link(ListenerPid, Socket, _Transport, Opts) ->
  {ok, Pid} = proc_lib:start_link(?MODULE, init, [ListenerPid, Socket, Opts]),
  {ok, Pid}.


init(ListenerPid, Socket, Opts) ->
  proc_lib:init_ack({ok, self()}),
  ok = ranch:accept_ack(ListenerPid),
  ok = inet:setopts(Socket, [{active,true}]),
  OnFix = proplists:get_value(on_fix, Opts, fun ?MODULE:on_fix/2),
  register(fix_test_server, self()),
  gen_server:enter_loop(?MODULE, [], #fix{socket = Socket, on_fix = OnFix}).


handle_info({tick, {MdReqId, Exchange, Symbol}, AvgPrice}, #fix{} = Fix) ->
  MdEntries = [[{md_entry_type, trade}, {md_entry_px, AvgPrice * (1+ 0.1*(random:uniform() - 0.5))}, {md_entry_size, 10 + random:uniform(50)}]],

  Instrument = [{md_req_id,MdReqId},{security_exchange,Exchange},{symbol,Symbol}],
  Body = Instrument ++ [{sending_time,fix:now()},{no_md_entries,length(MdEntries)}|lists:flatten(MdEntries)],
  Msg = #message{type = market_data_snapshot_full_refresh, body = Body},
  Fix1 = send(Msg, Fix),
  {noreply, Fix1};

handle_info({tcp, _Socket, Bin}, #fix{} = Fix) ->
  Fix1 = handle_input(Bin, Fix),
  {noreply, Fix1};

handle_info({tcp_closed, _}, #fix{} = Fix) ->
  {stop, normal, Fix}.


handle_input(<<>>, Fix) ->
  Fix;

handle_input(Bin, #fix{socket = Socket, client_seq = CliSeq, on_fix = Onfix} = Fix) ->
  case fix:decode_fields(Bin) of
    {ok, Msg1, _, Rest} ->
      {value, {msg_type, Type}, Msg2} = lists:keytake(msg_type, 1, Msg1),
      {value, {msg_seq_num, Seq}, Msg3} = lists:keytake(msg_seq_num, 1, Msg2),
      {value, {sender_comp_id, Sender}, Msg4} = lists:keytake(sender_comp_id, 1, Msg3),
      {value, {target_comp_id, Target}, Msg5} = lists:keytake(target_comp_id, 1, Msg4),
      Seq == CliSeq orelse throw({stop, {invalid_client_seq,Seq,CliSeq}, Fix}),
      Onfix(Type, Msg5),
      Fix1 = handle_fix(#message{type = Type, seq = Seq, sender = Sender, target = Target, body = Msg5}, Fix#fix{client_seq = Seq + 1}),
      handle_input(Rest, Fix1);
    {more, Count} ->
      {ok, Bytes} = gen_tcp:recv(Socket, Count),
      handle_input(<<Bin/binary, Bytes/binary>>, Fix);
    {error, _} = Error ->
      throw({stop, Error, Fix})
  end.


handle_fix(#message{type = logon, sender = Sender, target = Target, body = M}, #fix{} = Fix) ->
  Password = proplists:get_value(password, M),
  Grant = 
  Sender == <<"TestSender">> andalso
  Target == <<"TestTarget">> andalso
  Password == <<"TestPw">>,

  Grant == true orelse throw({stop, invalid_password, Fix}),
    SendFix1 = send(#message{type = logon, body = [{heart_bt_int, 30}, {encrypt_method, 0}]}, Fix#fix{sender = Target, target = Sender});
%    send(#message{type = test_request, body = [{test_req_id, "AARON"}]}, SendFix1);

handle_fix(#message{type = logout}, #fix{} = Fix) ->
  throw({stop, normal, Fix});

handle_fix(#message{type = market_data_request, body = Msg}, Fix) ->
  Exchange = proplists:get_value(security_exchange, Msg),
  Symbol = proplists:get_value(symbol, Msg),
  MdReqId = proplists:get_value(md_req_id, Msg),
  % ?debugFmt("request ~240p",[Msg]),
  case {Exchange, Symbol} of
    {<<"MICEX">>, <<"TEST", _/binary>>} ->
      timer:send_interval(5, self(), {tick, {MdReqId, Exchange,Symbol}, 45.0}),
      Fix;
    {<<"MICEX">>, <<"INVALID">>} ->
      send(#message{type = market_data_request_reject, body = [{md_req_id,MdReqId},{md_req_rej_reason,unknownsym},{text,<<"MDRequest failed">>}]}, Fix)
  end;

handle_fix(#message{type = test_request, body = Msg}, Fix) ->
    TestReqId = proplists:get_value(test_req_id, Msg),
    SendFix = Fix,
    send(#message{type = heartbeat, body = [{test_req_id, TestReqId}]}, SendFix);

handle_fix(Msg, Fix) ->
  ?debugFmt("fix ~240p", [Msg]),
  Fix.

terminate(_,_) -> ok.

encode(#message{type = Type, seq = Seq, sender = Sender, target = Target, body = Body}) ->
  fix:pack(Type, Body, Seq, Sender, Target).

send(#message{} = Msg, #fix{server_seq = Seq, socket = Socket, sender = Sender, target = Target} = Server) ->
    Encoded = encode(Msg#message{seq = Seq, sender = Sender, target = Target}),
  gen_tcp:send(Socket, Encoded),
  Server#fix{server_seq = Seq + 1}.


