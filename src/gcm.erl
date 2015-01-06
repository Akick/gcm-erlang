-module(gcm).
-behaviour(gen_server).

-export([start/2, stop/1, start_link/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([push/3, push/4, sync_push/3, sync_push/4]).

-define(SERVER, ?MODULE).
-define(MAX_ATTEMPT, 3).

-record(state, {key}).

start(Name, Key) ->
    gcm_sup:start_child(Name, Key).

stop(Name) ->
    gen_server:call(Name, stop).

push(Name, RegIds, Message) ->
    push(Name, RegIds, Message, 1).

push(Name, RegIds, Message, Attempt) ->
    gen_server:cast(Name, {send, RegIds, Message, Attempt}).

sync_push(Name, RegIds, Message) ->
    sync_push(Name, RegIds, Message, 1).

sync_push(Name, RegIds, Message, Attempt) ->
    gen_server:call(Name, {send, RegIds, Message, Attempt}).

%% OTP
start_link(Name, Key) ->
    gen_server:start_link({local, Name}, ?MODULE, [Key], []).

init([Key]) ->
    {ok, #state{key=Key}}.

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};

handle_call({send, RegIds, Message, Attempt}, _From, #state{key=Key} = State) ->
    Reply = do_push(RegIds, Message, Key, Attempt),
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send, RegIds, Message, Attempt}, #state{key=Key} = State) ->
    do_push(RegIds, Message, Key, Attempt),
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
do_push(RegIds, Message, Key, Attempt) ->
    error_logger:info_msg("Sending message: ~p to reg ids: ~p. Attempt number: ~p~n", [Message, RegIds, Attempt]),
    case gcm_api:push(RegIds, Message, Key) of
        {ok, GCMResult} ->
            handle_result(GCMResult, RegIds);
        {error, {retry, RetryAfter}} ->
            do_backoff(RetryAfter, RegIds, Message, Key, Attempt),
            {error, retry};
        {error, Reason} ->
            {error, Reason}
    end.

handle_result(GCMResult, RegIds) ->
    {_MulticastId, _SuccessesNumber, _FailuresNumber, _CanonicalIdsNumber, Results} = GCMResult,
    lists:map(fun({Result, RegId}) -> {RegId, parse(Result)} end, lists:zip(Results, RegIds)).

do_backoff(_, _, _, _, ?MAX_ATTEMPT + 1) ->
    ok;

do_backoff(RetryAfter, RegIds, Message, Key, Attempt) ->
    case RetryAfter of
        no_retry ->
            ok;
	_ ->
	    timer:apply_after(RetryAfter * 1000, ?MODULE, do_push, [RegIds, Message, Key, Attempt+1])
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
