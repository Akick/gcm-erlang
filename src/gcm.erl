-module(gcm).
-behaviour(gen_server).

-export([start/2, stop/1, start_link/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([push/3, push/4, sync_push/3, sync_push/4]).
-export([web_push/3, web_push/4, sync_webpush/3, sync_webpush/4]).

-define(SERVER, ?MODULE).
-define(RETRY, 3).

-type publicKey()    :: string()|binary().
-type authTokeny()   :: string()|binary().
-type regid()        :: binary().
-type subscription() :: {regid(), publicKey(), authTokeny()}.

-export_type([subscription/0]).

-record(state, {key}).

start(Name, Key) ->
    gcm_sup:start_child(Name, Key).

stop(Name) ->
    gen_server:call(Name, stop).

push(Name, RegIds, Message) ->
    push(Name, RegIds, Message, ?RETRY).

push(Name, RegIds, Message, Retry) ->
    gen_server:cast(Name, {send, RegIds, Message, Retry}).

web_push(Name, Message, Subscription) ->
    web_push(Name, Message, Subscription, ?RETRY).

web_push(Name, Message, Subscription, Retry) ->
    gen_server:cast(Name, {send_webpush, Message, Subscription, Retry}).

sync_push(Name, RegIds, Message) ->
    sync_push(Name, RegIds, Message, ?RETRY).

sync_push(Name, RegIds, Message, Retry) ->
    gen_server:call(Name, {send, RegIds, Message, Retry}).

sync_webpush(Name, Message, Subscription) ->
    sync_webpush(Name, Message, Subscription, ?RETRY).

sync_webpush(Name, Message, Subscription, Retry) ->
    gen_server:call(Name, {send_webpush, Message, Subscription, Retry}).

%% OTP
start_link(Name, Key) ->
    gen_server:start_link({local, Name}, ?MODULE, [Key], []).

init([Key]) ->
    {ok, #state{key=Key}}.

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};

handle_call({send, RegIds, Message, Retry}, _From, #state{key=Key} = State) ->
    Reply = do_push(RegIds, Message, Key, Retry),
    {reply, Reply, State};

handle_call({send_webpush, Message, Subscription, Retry}, _From, #state{key=Key} = State) ->
    Reply = do_web_push(Message, Key, Subscription, 0, Retry),
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({send, RegIds, Message, Retry}, #state{key=Key} = State) ->
    do_push(RegIds, Message, Key, Retry),
    {noreply, State};

handle_cast({send_webpush, Message, Subscription, Retry}, #state{key=Key} = State) ->
    do_web_push(Message, Key, Subscription, 0, Retry),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal
do_push(_, _, _, 0) ->
    ok;

do_push(RegIds, Message, Key, Retry) ->
    error_logger:info_msg("Sending message: ~p to reg ids: ~p retries: ~p.~n", [Message, RegIds, Retry]),
    case gcm_api:push(RegIds, Message, Key) of
        {ok, GCMResult} ->
            handle_result(GCMResult, RegIds);
        {error, {retry, RetryAfter}} ->
            do_backoff(RetryAfter, RegIds, Message, Retry),
            {error, retry};
        {error, Reason} ->
            {error, Reason}
    end.

do_web_push(_, _, _, _, 0) ->
    ok;

do_web_push(Message, Key, Subscription, PaddingLength, Retry) ->
    error_logger:info_msg("Sending web push message: ~p to subscription: ~p retries: ~p.~n", [Message, Subscription, Retry]),
    case gcm_api:web_push(Message, Key, Subscription, PaddingLength) of
        {ok, GCMResult} ->
            handle_result(GCMResult, Subscription);
        {error, {retry, RetryAfter}} ->
            do_backoff(RetryAfter, Subscription, Message, Retry),
            {error, retry};
        {error, Reason} ->
            {error, Reason}
    end.
    
handle_result(ok, {_,_,_} = _Subscription) ->
    [{<<"multicast_id">>, <<"">>},
     {<<"success">>,1},
     {<<"failure">>,0},
     {<<"canonical_ids">>,0},
     {<<"results">>, []}
    ];

handle_result(GCMResult, {_,_,_} = Subscription) ->
    {_MulticastId, _SuccessesNumber, _FailuresNumber, _CanonicalIdsNumber, Results} = GCMResult,
    lists:map(fun({Result, RegId}) -> {RegId, parse(Result)} end, lists:zip(Results, Subscription));

handle_result(GCMResult, RegIds) ->
    {_MulticastId, _SuccessesNumber, _FailuresNumber, _CanonicalIdsNumber, Results} = GCMResult,
    lists:map(fun({Result, RegId}) -> {RegId, parse(Result)} end, lists:zip(Results, RegIds)).

do_backoff(RetryAfter, {_,_,_} = Subscription, Message, Retry) ->
    case RetryAfter of
        no_retry ->
            ok;
        _ ->
            error_logger:info_msg("Received retry-after. Will retry: ~p times~n", [Retry-1]),
            timer:apply_after(RetryAfter * 1000, ?MODULE, web_push, [self(), Message, Subscription, Retry - 1])
    end;

do_backoff(RetryAfter, RegIds, Message, Retry) ->
    case RetryAfter of
        no_retry ->
            ok;
        _ ->
            error_logger:info_msg("Received retry-after. Will retry: ~p times~n", [Retry-1]),
            timer:apply_after(RetryAfter * 1000, ?MODULE, push, [self(), RegIds, Message, Retry - 1])
    end.

parse(Result) ->
    case {
      proplists:get_value(<<"error">>, Result),
      proplists:get_value(<<"message_id">>, Result),
      proplists:get_value(<<"registration_id">>, Result)
     } of
        {Error, undefined, undefined} ->
            Error;
        {undefined, _MessageId, undefined}  ->
            ok;
        {undefined, _MessageId, NewRegId} ->
            {<<"NewRegistrationId">>, NewRegId}
    end.
