%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2013, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 30 Dec 2013 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(fifo_s3_upload).

-behaviour(gen_server).

-include_lib("common/include/shared_json.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%% API
-export([new/2, new/12,
         start_link/12,
         part/2, part/3,
         abort/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3,
         done/1, done/2]).

-define(SERVER, ?MODULE).

-define(DONE_TIMEOUT, 100).

-define(POOL, s3_upload).

-record(state, {
          uploads = [],
          etags = [],
          part = 1,
          done_from,
          conf,
          id,
          bucket,
          key,
          channel,
          user_id,
          context,
          context_id,
          client_msg_id,
          size,
          url
         }).

%%%===================================================================
%%% API
%%%===================================================================

new(Key, Options) ->
    AKey = proplists:get_value(access_key, Options),
    SKey = proplists:get_value(secret_key, Options),
    Host = proplists:get_value(host, Options),
    Port = proplists:get_value(port, Options),
    Bucket = proplists:get_value(bucket, Options),

    UserId = proplists:get_value(user_id, Options),
    Context = proplists:get_value(context, Options),
    ContextId = proplists:get_value(context_id, Options),
    ClientMsgId = proplists:get_value(client_msg_id, Options),
    Size = proplists:get_value(size, Options),
    URL = proplists:get_value(url, Options),

    new(AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL).

new(AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId,ClientMsgId, Size, URL) when is_binary(Bucket) ->
    new(AKey, SKey, Host, Port, binary_to_list(Bucket), Key, UserId, Context, ContextId, ClientMsgId, Size, URL);

new(AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL) when is_binary(Key) ->
    new(AKey, SKey, Host, Port, Bucket, binary_to_list(Key), UserId, Context, ContextId, ClientMsgId, Size, URL);

new(AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL) ->
    fifo_s3_upload_sup:start_child(AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link(AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL) ->
    gen_server:start_link(?MODULE, [AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL], []).

part(PID, Part) ->
    part(PID, Part, infinity).

part(PID, Data, Timeout) ->
    case process_info(PID) of
        undefined ->
            {error, failed};
        _ ->
            case gen_server:call(PID, part, Timeout) of
                {ok, Worker, D} ->
                    gen_server:cast(Worker, {part, D, Data}),
                    ok;
                E ->
                    E
            end
    end.

done(PID) ->
    done(PID, infinity).

done(PID, Timeout) ->
    case process_info(PID) of
        undefined ->
            {error, failed};
        _ ->
            gen_server:call(PID, done, Timeout)
    end.

abort(PID) ->
    case process_info(PID) of
        undefined ->
            {error, failed};
        _ ->
            gen_server:cast(PID, abort)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([AKey, SKey, Host, Port, Bucket, Key, UserId, Context, ContextId, ClientMsgId, Size, URL]) ->
    Conf = fifo_s3:make_config(AKey, SKey, Host, Port),
    {ok, ChannelCon} = rabbit_pool_man:get_conn(uploadit_publishers),
    %% Monitor the channel in case it goes down
    _ChanRefCon = monitor(process, ChannelCon),
   lager:debug("ClientMsgId:~p",[ClientMsgId]),
    %TODO must notify client when this process dies abnormally.. includin when channel dies
    case erlcloud_s3:start_multipart(Bucket, Key, [], [], Conf) of
        {ok, [{uploadId, Id}]} ->
            {ok, #state{
                    bucket = Bucket,
                    key = Key,
                    conf = Conf,
                    id = Id,
                    channel = ChannelCon,
                    user_id = UserId,
                    context = Context,
                    client_msg_id = tcl_tools:binarize([ClientMsgId]),
                    context_id = tcl_tools:binarize([ContextId]),
                    size = Size,
                    url = tcl_tools:binarize([URL])
                   }};
        E ->
            {stop, E}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(part, _From, State =
                #state{
                   bucket=B, key=K, conf=C, id=Id, part=P,
                   uploads = Uploads}) ->
    Worker = poolboy:checkout(?POOL, true, infinity),
    Ref =  make_ref(),
    Reply = {ok, Worker, {self(), Ref, B, K, Id, P, C}},
    {reply, Reply, State#state{uploads=[{Ref, Worker} | Uploads], part=P + 1}};

handle_call(done, _From, State = #state{bucket=B, key=K, conf=C, id=Id,
                                        etags=Ts, uploads=[]}) ->
    erlcloud_s3:complete_multipart(B, K, Id, lists:sort(Ts), [], C),
    {stop, normal, ok, State};

handle_call(done, From, State) ->
    timer:send_after(?DONE_TIMEOUT, {done, From}),
    {reply, ok, State};

handle_call(abort, _From, State = #state{bucket=B, key=K, conf=C, id=Id}) ->
    erlcloud_s3:abort_multipart(B, K, Id, [], [], C),
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({done, From}, State = #state{bucket=B, key=K, conf=C, id=Id,
                                         etags=Ts, uploads=[],
                                         channel = Channel,
                                         user_id = UserId,
                                         context = Context,
                                         context_id = ContextId,
                                         client_msg_id = ClientMsgId,
                                         size = Size,
                                         url     = URL   }) when Context == "message" ->
    erlcloud_s3:complete_multipart(B, K, Id, lists:sort(Ts), [], C),

   StatusMsg = #x_chat_file_status{ file_status = <<"ready">>,
                                    chat_id = ContextId,
                                    file = URL,
                                    client_msg_id =  tcl_tools:ensure(binary, ClientMsgId),
                                    size = tcl_tools:ensure(integer, Size)
                                    },
   RequestMsg = #request{ type = <<"request">>,
                          request_type = p_get_request_type(Context),
                          version = 1,
                          user_id = tcl_tools:ensure(binary, UserId),
                          request_action = <<"new">>,
                          reply_to = <<"">>,
                          correlation_id = <<"">>,
                          data = StatusMsg
                    },
    lager:debug("StatusMsg:~p",[StatusMsg]),
    {Exch, RoutingKey} = p_get_routing(Context, ContextId),

    %TODO  remove hardcoded exch name
    Msg = common_data:new_internal_msg(request, RequestMsg, RequestMsg#request.version),
    MsgOut = common_data:new_msg_out(Exch, Channel, RoutingKey, <<"application/x-erlang">>,
				     term_to_binary(Msg), <<"request">>),

    lager:debug("MsgOut:~p~n",[MsgOut]),
    % TODO set reply_to
    ok = amqp_util:send_messages([MsgOut]),

    gen_server:reply(From, ok),
    {stop, normal, State};

% dont send updates for any uploads other than chat msgs
handle_info({done, From}, State = #state{bucket=B, key=K, conf=C, id=Id,
    etags=Ts, uploads=[],
    context = Context
    }) when Context =/= "message" ->

    erlcloud_s3:complete_multipart(B, K, Id, lists:sort(Ts), [], C),
    gen_server:reply(From, ok),

    {stop, normal, State};

handle_info({done, From}, State) ->
    lager:debug("waiting for done",[]),
    timer:send_after(?DONE_TIMEOUT, {done, From}),
    {noreply, State};

handle_info({ok, Ref, TagData}, State = #state{uploads=Uploads, etags=ETs}) ->
    Uploads1 = [{R, W} || {R, W} <- Uploads, R =/= Ref],
    {noreply, State#state{uploads=Uploads1, etags=[TagData | ETs]}};
handle_info({error, _Ref, E}, State) ->
    {stop, E, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(normal, #state{channel = Channel} = _State) ->
    case Channel of undefined -> ok ; _ -> catch amqp_channel:close(Channel) end,
    ok;

terminate(_Reason, #state{bucket=B, key=K, conf=C, id=Id, channel=Channel}) ->
    case Channel of undefined -> ok ; _ -> catch amqp_channel:close(Channel) end,
    erlcloud_s3:abort_multipart(B, K, Id, [], [], C).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
p_get_routing("message", ContextId) ->
    {<<"in.chat.exch">>, tcl_tools:binarize(["in.chat.direct.", ContextId])};

p_get_routing("campaign", _ContextId) ->
    {<<"in.tasks.exch">>, <<"in.tasks.internal">>}.

p_get_request_type("message") -> <<"x_chat_file_status">>;
p_get_request_type("campaign") -> <<"x_campaign_file_status">>.
