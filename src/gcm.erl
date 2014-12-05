-module(gcm).

-behaviour(gen_server).

-export([start/2, start/3, stop/1, start_link/2, start_link/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([push/3, sync_push/3, update_error_fun/2]).

-define(SERVER, ?MODULE).

-define(BASEURL, "https://android.googleapis.com/gcm/send").

-record(state, {key, retry_after, error_fun}).

start(Name, Key) ->
    start(Name, Key, fun handle_error/2).

start(Name, Key, ErrorFun) ->
    gcm_sup:start_child(Name, Key, ErrorFun).

start_link(Name, Key) ->
    start_link(Name, Key, fun handle_error/2).

start_link(Name, Key, ErrorFun) ->
    gen_server:start_link({local, Name}, ?MODULE, [Key, ErrorFun], []).

stop(Name) ->
    gen_server:call(Name, stop).

push(Name, RegIds, Message) ->
    gen_server:cast(Name, {send, RegIds, Message}).

sync_push(Name, RegIds, Message) ->
    gen_server:call(Name, {send, RegIds, Message}).

update_error_fun(Name, Fun) ->
    gen_server:cast(Name, {error_fun, Fun}).

init([Key, ErrorFun]) ->
    {ok, #state{key=Key, retry_after=0, error_fun=ErrorFun}}.

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};

handle_call({send, RegIds, Message}, _From, #state{key=Key} = State) ->
    {reply, do_push(RegIds, Message, Key, undefined), State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({send, RegIds, Message}, #state{key=Key, error_fun=ErrorFun} = State) ->
    do_push(RegIds, Message, Key, ErrorFun),
    {noreply, State};

handle_cast({error_fun, Fun}, State) ->
    NewState = State#state{error_fun=Fun},
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


do_push(RegIds, Message, Key, ErrorFun) ->
    error_logger:info_msg("Message=~p; RegIds=~p~n", [Message, RegIds]),
    Request = jsx:encode([{<<"registration_ids">>, RegIds}|Message]),
    ApiKey = string:concat("key=", Key),

    try httpc:request(post, {?BASEURL, [{"Authorization", ApiKey}], "application/json", Request}, [], []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            Json = jsx:decode(response_to_binary(Body)),
            handle_push_result(Json, RegIds, ErrorFun);
        {error, Reason} ->
	    error_logger:error_msg("Error in request. Reason was: ~p~n", [Reason]),
            {error, Reason};
        {ok, {{_, 400, _}, _, _}} ->
	    error_logger:error_msg("Error in request. Reason was: json_error~n", []),
            {error, json_error};
        {ok, {{_, 401, _}, _, _}} ->
	    error_logger:error_msg("Error in request. Reason was: authorization error~n", []),
            {error, auth_error};
        {ok, {{_, Code, _}, Headers, _}} when Code >= 500 andalso Code =< 599 ->
	    RetryTime = headers_parser:retry_after_from(Headers),
	    error_logger:error_msg("Error in request. Reason was: retry. Will retry in: ~p~n", [RetryTime]),
	    do_backoff(RetryTime, RegIds, Message, Key, ErrorFun) ,
            {error, retry};
        {ok, {{_StatusLine, _, _}, _, _Body}} ->
	    error_logger:error_msg("Error in request. Reason was: timeout~n", []),
            {error, timeout};
        OtherError ->
	    error_logger:error_msg("Error in request. Reason was: ~p~n", [OtherError]),
            {noreply, unknown}
    catch
        Exception ->
	    error_logger:error_msg("Error in request. Exception ~p while calling URL: ~p~n", [Exception, ?BASEURL]),
            {error, Exception}
    end.


handle_push_result(Json, RegIds, undefined) ->
    {_MulticastId, _SuccessesNumber, _FailuresNumber, _CanonicalIdsNumber, Results} = fields_from(Json),
    lists:map(fun({Result, RegId}) -> 
		      parse_result(Result, RegId, fun(E, I) -> {E, I} end) 
	      end, lists:zip(Results, RegIds));

handle_push_result(Json, RegIds, ErrorFun) ->
    {_MulticastId, _SuccessesNumber, FailuresNumber, CanonicalIdsNumber, Results} = fields_from(Json),
    case to_be_parsed(FailuresNumber, CanonicalIdsNumber) of
        true ->
            lists:foreach(fun({Result, RegId}) -> parse_result(Result, RegId, ErrorFun) end,
			  lists:zip(Results, RegIds));
        false ->
            ok
    end.


do_backoff(RetryTime, RegIds, Message, Key, ErrorFun) ->
    case RetryTime of
	{ok, Time} ->
	    timer:apply_after(Time * 1000, ?MODULE, do_push, [RegIds, Message, Key, ErrorFun]);
	no_retry ->
	    ok
    end.

response_to_binary(Json) when is_binary(Json) ->
    Json;

response_to_binary(Json) when is_list(Json) ->
    list_to_binary(Json).

fields_from(Json) ->
    {
      proplists:get_value(<<"multicast_id">>, Json),
      proplists:get_value(<<"success">>, Json),
      proplists:get_value(<<"failure">>, Json),
      proplists:get_value(<<"canonical_ids">>, Json),
      proplists:get_value(<<"results">>, Json)
    }.

to_be_parsed(0, 0) -> false;

to_be_parsed(_FailureNumber, _CanonicalNumber) -> true.

parse_result(Result, RegId, ErrorFun) ->
    case {
      proplists:get_value(<<"error">>, Result),
      proplists:get_value(<<"message_id">>, Result),
      proplists:get_value(<<"registration_id">>, Result)
     } of
        {Error, undefined, undefined} when Error =/= undefined ->
            ErrorFun(Error, RegId);
        {undefined, MessageId, undefined} when MessageId =/= undefined ->
            ok;
        {undefined, MessageId, NewRegId} when MessageId =/= undefined andalso NewRegId =/= undefined ->
            ErrorFun(<<"NewRegistrationId">>, {RegId, NewRegId})
    end.

handle_error(<<"NewRegistrationId">>, {RegId, NewRegId}) ->
    error_logger:info_msg("Message sent. Update id ~p with new id ~p.~n", [RegId, NewRegId]),
    ok;

handle_error(<<"Unavailable">>, RegId) ->
    %% The server couldn't process the request in time. Retry later with exponential backoff.
    error_logger:error_msg("unavailable ~p~n", [RegId]),
    ok;

handle_error(<<"InternalServerError">>, RegId) ->
    % GCM had an internal server error. Retry later with exponential backoff.
    error_logger:error_msg("internal server error ~p~n", [RegId]),
    ok;

handle_error(<<"InvalidRegistration">>, RegId) ->
    %% Invalid registration id in database.
    lager:error("invalid registration ~p~n", [RegId]),
    ok;

handle_error(<<"NotRegistered">>, RegId) ->
    %% Application removed. Delete device from database.
    error_logger:error_msg("not registered ~p~n", [RegId]),
    ok;

handle_error(UnexpectedError, RegId) ->
    %% There was an unexpected error that couldn't be identified.
    error_logger:error_msg("unexpected error ~p in ~p~n", [UnexpectedError, RegId]),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Other possible errors:					%%
%%	<<"InvalidPackageName">>				%%
%%      <<"MissingRegistration">>				%%
%%	<<"MismatchSenderId">>					%%
%%	<<"MessageTooBig">>					%%
%%      <<"InvalidDataKey">>					%%
%%	<<"InvalidTtl">>					%%
%%								%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
